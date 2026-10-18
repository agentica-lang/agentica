"""A socket handed to workers over a Channel.

The program listens on port 0 and prints the port; an independent Python peer
connects six clients, and the loop of the workers ends when the channel closes.
"""
import re

from tests.agentica_test import FIXTURES, PYTHON, WAIT_SECONDS, compile_agc, run, start_vm

CLIENTS = 6

PROGRAM = """\
struct Pool
  sockets: Channel[Socket]
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
  sockets: Channel[Socket] = Channel.new(2)
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
