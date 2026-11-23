"""Channels on the VM against independent Python peers.

A socket handed to workers: the program listens on port 0 and prints the port; an independent Python peer
connects six clients, and the loop of the workers ends when the channel closes.

A close with a reason: a list of sends, receives and closes against a Python model of one channel
(tests/fixtures/channel-close-peer.py), and producers on four schedulers whose consumer gets every value, then the
reason.
"""
import json
import random
import re

import pytest

from tests.agentica_test import (FIXTURES, PYTHON, WAIT_SECONDS, compile_agc, compile_text, run, run_vm, start_vm,
                                 vm_environment)

CLIENTS = 6

PROGRAM = """\
struct Pool
  sockets: Channel[TCP.Socket]
  id: Int
end

def serve(pool: Pool) -> Int
  handled = 0
  while true
    case pool.sockets.recv(10000)
      ok(socket) ->
        line = Result.unwrap!(TCP.read_line(socket, 10000))
        Result.unwrap!(TCP.send(socket, "worker #{pool.id} got #{line}\\n", 10000))
        TCP.close(socket)
        handled += 1
      error(_) -> break
    end
  end
  return handled
end

def main() -> Void
  sockets: Channel[TCP.Socket] = Channel.new(2)
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  puts(TCP.local_port(listener))
  IO.flush()
  workers = [Task.spawn(&serve, Pool(sockets: sockets, id: 0)),
             Task.spawn(&serve, Pool(sockets: sockets, id: 1)),
             Task.spawn(&serve, Pool(sockets: sockets, id: 2))]
  i = 0
  while i < 6
    Result.unwrap!(sockets.send(Result.unwrap!(TCP.accept(listener, 10000)), 10000))
    i += 1
  end
  sockets.close
  handled = workers.map do |worker|
    Task.await(worker)
  end
  TCP.close_listener(listener)
  puts("handled #{handled.reduce(0) do |sum, n| sum + n end}")
end
"""


def test_socket_handed_to_a_worker_is_served_and_the_loop_ends_when_the_channel_closes(tmp_path):
    # The VM runs beside the peer, so it is a Child read line by line.
    program = tmp_path / "pool.agc"
    program.write_text(PROGRAM, encoding="utf-8")
    vm = start_vm(compile_agc(program, tmp_path / "pool.agcb"))
    try:
        port = int(vm.next_line())
        assert port > 0
        peer = run([PYTHON, FIXTURES / "channel-peer.py", port, CLIENTS], timeout=WAIT_SECONDS)
        assert peer.code == 0, peer.stderr
        replies = peer.stdout.splitlines()
        assert len(replies) == CLIENTS
        for i, line in enumerate(replies):
            assert re.fullmatch(r"%d worker [012] got msg %d" % (i, i), line), line
        assert vm.next_line() == "handled 6"
        assert vm.wait() == 0, "the program ends"
    finally:
        vm.stop()


CLOSE_HELPERS = """\
def failure(text: String) -> Result[Void] = error(text, kind: "stream.cut")

def close_with(ch: Channel[Int], text: String) -> Void
  case failure(text)
    ok(_) -> ch.close
    error(e) -> ch.close(e)
  end
end

def got(r: Result[Int]) -> String
  case r
    ok(n) -> n.to_s
    error(e) -> "#{e.kind} #{e.message}"
  end
end

def sent(r: Result[Void]) -> String
  case r
    ok(_) -> "ok"
    error(e) -> "#{e.kind} #{e.message}"
  end
end

"""

CLOSE_STATEMENTS = {
    "new": "ch = Channel.new(3)",
    "send": 'puts("send {a} #{{sent(ch.send({a}, 0))}}")',
    "address_send": 'puts("address_send {a} #{{sent(ch.address.send({a}, 0))}}")',
    "recv": 'puts("recv #{{got(ch.recv(0))}}")',
    "close": "ch.close",
    "close_reason": 'close_with(ch, "{a}")',
    "closed": 'puts("closed? #{{ch.closed?}}")',
    "empty": 'puts("empty? #{{ch.empty?}}")',
}

ROUND = """\
struct Round
  ch: Channel[Int]
  count: Int
  reason: String
end

"""

ROUNDS = """\
def produce(round: Round) -> Void
  for n in 1..round.count
    _ = round.ch.send(n, 10000)
  end

  if round.reason == ""
    round.ch.close
  else
    close_with(round.ch, round.reason)
  end
end

def run_round(count: Int, reason: String) -> Void
  ch: Channel[Int] = Channel.new(2)
  producer = Task.spawn(&produce, Round(ch: ch, count: count, reason: reason))
  while true
    r = ch.recv(10000)
    puts("recv #{got(r)}")
    break if !r.ok?
  end

  Task.await(producer)
end

"""


def peer_lines(ops, capacity):
    peer = run([PYTHON, FIXTURES / "channel-close-peer.py", "--capacity", str(capacity)],
               stdin=json.dumps(ops).encode("utf-8"))
    assert peer.code == 0, peer.stderr
    return peer.stdout.splitlines()


def close_operations(seed, count):
    rng = random.Random(seed)
    # Sends and receives are common and a close rare, so most channels fill, drain and close with values left.
    names = ["send"] * 6 + ["recv"] * 6 + ["address_send", "closed", "empty", "close", "close_reason", "new"]
    ops = []
    for i in range(count):
        name = rng.choice(names)
        argument = "reason %d" % i if name == "close_reason" else rng.randint(0, 99)
        ops.append([name, argument])
    return ops


def test_one_channel_closed_with_a_reason_does_what_the_python_model_does(tmp_path):
    ops = close_operations(23, 800)
    lines = ["  " + CLOSE_STATEMENTS[name].format(a=argument) for name, argument in ops]
    text = CLOSE_HELPERS + "def main() -> Void\n  ch: Channel[Int] = Channel.new(3)\n" + "\n".join(lines) + "\nend\n"
    vm = run_vm(compile_text(text, "close_ops", tmp_path), "--schedulers", "1", env=vm_environment())
    assert vm.code == 0, vm.stderr
    expected = peer_lines(ops, 3)
    assert vm.stdout.splitlines() == expected
    assert any(line.startswith("recv stream.cut reason") for line in expected)
    assert any(line.startswith("send") and "stream.cut" in line for line in expected)


@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_a_producer_on_another_scheduler_gives_every_value_then_the_reason(tmp_path, schedulers):
    rng = random.Random(29)
    rounds = [(rng.randint(1, 12), rng.choice(["", "cut %d" % i])) for i in range(150)]
    calls = ["  run_round(%d, \"%s\")" % (count, reason) for count, reason in rounds]
    text = ROUND + CLOSE_HELPERS + ROUNDS + "def main() -> Void\n" + "\n".join(calls) + "\nend\n"
    vm = run_vm(compile_text(text, "close_rounds", tmp_path), "--schedulers", schedulers, env=vm_environment())
    assert vm.code == 0, vm.stderr
    ops = []
    for count, reason in rounds:
        ops += [["new", 0]] + [["put", n] for n in range(1, count + 1)]
        ops.append(["close_reason", reason] if reason else ["close", 0])
        ops += [["recv", 0]] * (count + 1)
    assert vm.stdout.splitlines() == peer_lines(ops, 100)
