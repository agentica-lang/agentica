"""System.subscribe: OS signals as values on a channel (issue #1477).

The peer is this test: it starts the VM, sends the signals with os.kill and reads what the program prints. Each case
runs at one scheduler and at four, where the I/O thread takes the signal and a scheduler delivers it. Windows has no
subscription: System.subscribe returns a system.signal error there, which the last case checks.
"""
import os
import signal
import time

import pytest

from tests.agentica_test import FIXTURES, PYTHON, WINDOWS, Child, compile_agc, host_only, scaled, start_vm, vm_command

WAIT_SECONDS = scaled(10)
POSIX = "System.subscribe needs POSIX signals; on Windows it returns a system.signal error, which " \
        "test_subscribe_answers_on_every_system checks"
SCHEDULERS = pytest.mark.parametrize("schedulers", [1, 4])

# Waits in the way its first argument names, with a Term delivered meanwhile, then receives it. `channel` waits on the
# signal channel itself with a far deadline, so the scheduler sleeps in the loop until the signal wakes it.
WAITS = """\
def wait(ch: Channel[System.Signal], mode: String, python: String) -> Void
  case mode
    "running" ->
      _n = 0
      while ch.empty?
        _n += 1
      end

    "sleeping" -> Task.sleep(1500)
    "process" ->
      p = Process.spawn(python, ["-c", "import time; time.sleep(1.5)"]).unwrap!
      Process.wait(p, 10000).unwrap!
    "deadline" ->
      while !ch.recv(1).ok?
        Task.sleep(0)
      end

      puts("got System.Signal.Term")
    _ -> nil
  end

end

def main() -> Void
  args = System.args()
  ch = System.subscribe([System.Signal.Term]).unwrap!
  puts("ready")
  IO.flush()
  wait(ch, args[0], args[1])
  if args[0] != "deadline"
    puts("got #{ch.recv(60000).unwrap!}")
  end

  puts(ch.recv(0).message)
end
"""

# Two tasks subscribed to Term, one of them to Usr1 too: each prints what it receives, prefixed by its name.
TWO_TASKS = """\
def listen(name: String, signals: List[System.Signal], count: Int, ready: Channel[String]) -> Void
  ch = System.subscribe(signals).unwrap!
  ready.send(name, 1000).unwrap!
  count.times do |_n|
    puts("#{name} #{ch.recv(60000).unwrap!}")
    IO.flush()
  end

end

def main() -> Void
  ready: Channel[String] = Channel.new(2)
  a = Task.spawn do listen("a", [System.Signal.Term], 1, ready) end
  b = Task.spawn do listen("b", [System.Signal.Term, System.Signal.Usr1, System.Signal.Term], 2, ready) end
  ready.recv(5000).unwrap!
  ready.recv(5000).unwrap!
  puts("ready")
  IO.flush()
  Task.await(a)
  Task.await(b)
end
"""

# A subscription ended by its close, by the return, crash or cancel of its task, then subscribed again, or not.
ENDS = """\
def subscriber(ready: Channel[String], how: String) -> Void
  ch = System.subscribe([System.Signal.Usr1]).unwrap!
  ready.send("subscribed", 1000).unwrap!
  case how
    "close" -> ch.close
    "crash" -> _ = [1][5]
    "cancel" -> Task.sleep(60000)
    _ -> nil
  end

end

def main() -> Void
  how = System.args()[0]
  ready: Channel[String] = Channel.new(1)
  downs: Channel[String] = Channel.new(1)
  t = Task.spawn do subscriber(ready, how) end
  Task.monitor(t, downs) do |down| down.reason.to_s end
  ready.recv(5000).unwrap!
  if how == "cancel"
    Task.cancel(t)
  end

  downs.recv(5000).unwrap!
  if System.args()[1] == "again"
    ch = System.subscribe([System.Signal.Usr1]).unwrap!
    puts("ready")
    IO.flush()
    puts("got #{ch.recv(60000).unwrap!}")
  else
    puts("ready")
    IO.flush()
    Task.sleep(60000)
  end

end
"""

# A burst: the program reads nothing while the test sends 1,000 Term and one Usr1, then counts what is queued.
BURST = """\
def main() -> Void
  ch = System.subscribe([System.Signal.Term, System.Signal.Usr1]).unwrap!
  puts("ready")
  IO.flush()
  _ = IO.gets()
  Task.sleep(200)
  got: List[String] = []
  while true
    case ch.recv(0)
      ok(s) -> got = got.append(s.to_s)
      error(_) -> break
    end

  end

  puts(got.sort.join(" "))
end
"""

# What a subscribed program sees of its channel, and what a child it spawns inherits.
API = """\
def main() -> Void
  ch = System.subscribe([System.Signal.Term, System.Signal.Term]).unwrap!
  case ch.send(System.Signal.Term, 0)
    ok(_) -> puts("sent")
    error(e) -> puts("#{e.kind}: #{e.message}")
  end

  puts(ch.address.send(System.Signal.Term, 0).message)
  code = (
    "import signal; print(signal.getsignal(signal.SIGTERM) == signal.SIG_DFL, " +
    "signal.getsignal(signal.SIGUSR1) == signal.SIG_DFL, sorted(signal.pthread_sigmask(signal.SIG_BLOCK, [])))"
  )
  p = Process.spawn_captured(System.args()[0], ["-c", code]).unwrap!
  puts(Process.read_line(p, 10000).unwrap!)
  Process.wait(p, 10000).unwrap!
  ch.close
  puts(ch.recv(0).message)
end
"""

# Many lines through the blocking stdout fallback while the test sends subscribed signals: no write fails.
LINES = """\
def main() -> Void
  _ch = System.subscribe([System.Signal.Usr1]).unwrap!
  line = "x" * 1000
  IO.warn("ready")
  500.times do |n|
    puts("#{n} #{line}")
  end

end
"""

READY_AND_SLEEP = """\
def main() -> Void
  ch = System.subscribe([System.Signal.Term]).unwrap!
  puts("ready")
  IO.flush()
  Task.sleep(60000)
  puts(ch.recv(0).message)
end
"""

# A signal that comes before the subscription, at the start of the VM or a little later, takes the stop path.
LATE = """\
def main() -> Void
  Task.sleep(5000)
  _ch = System.subscribe([System.Signal.Term]).unwrap!
  puts("subscribed")
end
"""

IGNORED = """\
def main() -> Void
  case System.subscribe([System.Signal.Int])
    ok(_) -> puts("subscribed")
    error(e) -> puts("#{e.kind}: #{e.message}")
  end

end
"""


def bytecode(text, tmp_path, name="program"):
    source = tmp_path / (name + ".agc")
    source.write_text(text, encoding="utf-8")
    return compile_agc(source, tmp_path / (name + ".agcb"))


def start(adopt, tmp_path, text, *args, schedulers=1, flags=(), **options):
    return adopt(start_vm(bytecode(text, tmp_path), *args, flags=("--schedulers", str(schedulers), *flags), **options))


@host_only(WINDOWS, POSIX)
@SCHEDULERS
@pytest.mark.parametrize("mode", ["running", "channel", "sleeping", "process", "deadline"])
def test_a_signal_reaches_the_subscriber_however_it_waits(tmp_path, adopt, schedulers, mode):
    vm = start(adopt, tmp_path, WAITS, mode, PYTHON, schedulers=schedulers)
    assert vm.next_line(WAIT_SECONDS) == "ready"
    sent = time.monotonic()
    os.kill(vm.process.pid, signal.SIGTERM)
    assert vm.next_line(WAIT_SECONDS) == "got System.Signal.Term"
    # A subscribed signal never starts the stop path, and one value is queued for it.
    assert vm.next_line(WAIT_SECONDS) == "channel: timed out"
    assert vm.wait(WAIT_SECONDS) == 0
    if mode == "channel":
        assert time.monotonic() - sent < scaled(5), "the signal wakes a scheduler that sleeps in the loop"


@host_only(WINDOWS, POSIX)
@SCHEDULERS
def test_two_tasks_get_each_signal_they_subscribed_to(tmp_path, adopt, schedulers):
    vm = start(adopt, tmp_path, TWO_TASKS, schedulers=schedulers)
    assert vm.next_line(WAIT_SECONDS) == "ready"
    os.kill(vm.process.pid, signal.SIGTERM)
    first = sorted([vm.next_line(WAIT_SECONDS), vm.next_line(WAIT_SECONDS)])
    assert first == ["a System.Signal.Term", "b System.Signal.Term"]
    os.kill(vm.process.pid, signal.SIGUSR1)
    assert vm.next_line(WAIT_SECONDS) == "b System.Signal.Usr1"
    assert vm.wait(WAIT_SECONDS) == 0


@host_only(WINDOWS, POSIX)
@SCHEDULERS
@pytest.mark.parametrize("how", ["close", "return", "crash", "cancel"])
def test_an_ended_subscription_gives_the_signal_back_to_the_stop_path(tmp_path, adopt, schedulers, how):
    vm = start(adopt, tmp_path, ENDS, how, "once", schedulers=schedulers)
    assert vm.next_line(WAIT_SECONDS) == "ready"
    os.kill(vm.process.pid, signal.SIGUSR1)
    assert vm.wait(WAIT_SECONDS) == -signal.SIGUSR1


@host_only(WINDOWS, POSIX)
@SCHEDULERS
def test_a_signal_can_be_subscribed_to_again_after_its_subscription_ended(tmp_path, adopt, schedulers):
    vm = start(adopt, tmp_path, ENDS, "close", "again", schedulers=schedulers)
    assert vm.next_line(WAIT_SECONDS) == "ready"
    os.kill(vm.process.pid, signal.SIGUSR1)
    assert vm.next_line(WAIT_SECONDS) == "got System.Signal.Usr1"
    assert vm.wait(WAIT_SECONDS) == 0


@host_only(WINDOWS, POSIX)
@SCHEDULERS
def test_a_burst_queues_one_value_per_signal(tmp_path, adopt, schedulers):
    vm = start(adopt, tmp_path, BURST, schedulers=schedulers, stdin=True)
    assert vm.next_line(WAIT_SECONDS) == "ready"
    for _ in range(1000):
        os.kill(vm.process.pid, signal.SIGTERM)
    os.kill(vm.process.pid, signal.SIGUSR1)
    time.sleep(0.2)
    vm.process.stdin.write(b"go\n")
    vm.process.stdin.flush()
    assert vm.next_line(WAIT_SECONDS) == "System.Signal.Term System.Signal.Usr1"
    assert vm.wait(WAIT_SECONDS) == 0


@host_only(WINDOWS, POSIX)
@SCHEDULERS
def test_the_signal_channel_is_read_only_and_a_child_starts_with_default_signals(tmp_path, adopt, schedulers):
    vm = start(adopt, tmp_path, API, PYTHON, schedulers=schedulers)
    assert vm.next_line(WAIT_SECONDS) == "argument: signal: channel is read only"
    assert vm.next_line(WAIT_SECONDS) == "signal: channel is read only"
    assert vm.next_line(WAIT_SECONDS) == "True True []"
    assert vm.next_line(WAIT_SECONDS) == "channel: closed"
    assert vm.wait(WAIT_SECONDS) == 0


@host_only(WINDOWS, POSIX)
def test_a_subscribed_signal_does_not_break_a_blocking_write(tmp_path, adopt):
    vm = adopt(Child([*vm_command(), "--schedulers", "1", "--", bytecode(LINES, tmp_path)], capture_stderr=True,
                     read_stdout=False, env={**os.environ, "AGENTICA_VM_TEST_BLOCKING_OUTPUT": "1"}))
    assert vm.next_stderr_line(WAIT_SECONDS) == "ready"
    # The pipe is full and the VM blocks in write(2): each signal lands in the middle of it.
    time.sleep(0.3)
    for _ in range(20):
        os.kill(vm.process.pid, signal.SIGUSR1)
        time.sleep(0.01)
    lines = vm.process.stdout.read().decode().splitlines()
    assert vm.wait(WAIT_SECONDS) == 0, vm.stderr_text()
    assert [line.split(" ")[0] for line in lines] == [str(n) for n in range(500)]
    assert vm.stderr_text() == "ready\n"


@host_only(WINDOWS, POSIX)
@pytest.mark.parametrize("flags", [(), ("--sandbox",)])
def test_a_signal_at_start_takes_the_stop_path_and_quit_stops_a_subscribed_program(tmp_path, adopt, flags):
    vm = start(adopt, tmp_path, LATE, flags=flags)
    os.kill(vm.process.pid, signal.SIGTERM)
    assert vm.wait(WAIT_SECONDS) == -signal.SIGTERM
    assert (vm.stdout_text(), vm.stderr_text()) == ("", "")
    # Subscribing needs no permission: --sandbox allows it.
    vm = start(adopt, tmp_path, READY_AND_SLEEP, flags=flags)
    assert vm.next_line(WAIT_SECONDS) == "ready"
    os.kill(vm.process.pid, signal.SIGTERM)
    time.sleep(0.3)
    assert vm.process.poll() is None, "the subscription keeps the run going"
    os.kill(vm.process.pid, signal.SIGQUIT)
    assert vm.wait(WAIT_SECONDS) == 128 + signal.SIGQUIT


@host_only(WINDOWS, POSIX)
def test_a_signal_during_the_end_of_the_run_takes_the_stop_path(tmp_path, adopt):
    fifo = tmp_path / "fifo"
    peer = adopt(Child([PYTHON, FIXTURES / "stop-peer.py", "fill", fifo], stdin=True))
    assert peer.next_line(WAIT_SECONDS) == "ready"
    text = """\
def main() -> Void
  _ch = System.subscribe([System.Signal.Term]).unwrap!
  f = File.open(System.args()[0], "write", 5000).unwrap!
  File.write(f, "x", 1000).unwrap!
  puts("ready")
  IO.flush()
end
"""
    vm = start(adopt, tmp_path, text, fifo)
    assert vm.next_line(WAIT_SECONDS) == "ready"
    time.sleep(0.3)
    # main has returned and the flush waits for the full FIFO: the subscription is over, so Terms end the run long
    # before the 30-second flush limit. Term goes in a loop: on a loaded runner the first may still reach the channel.
    deadline = time.monotonic() + min(scaled(5), 25)
    while vm.process.poll() is None and time.monotonic() < deadline:
        os.kill(vm.process.pid, signal.SIGTERM)
        time.sleep(0.3)
    assert vm.wait(1) == -signal.SIGTERM


@host_only(WINDOWS, "a signal inherited as ignored (nohup) has no Windows form")
def test_a_signal_the_vm_started_ignoring_cannot_be_subscribed_to(tmp_path, adopt):
    code = bytecode(IGNORED, tmp_path)
    vm = adopt(Child([PYTHON, FIXTURES / "stop-peer.py", "launch", "ignore", *vm_command(), "--", code]))
    assert vm.next_line(WAIT_SECONDS) == "system.signal: signal: ignored when the program started"
    assert vm.wait(WAIT_SECONDS) == 0


def test_subscribe_answers_on_every_system(tmp_path, adopt):
    """The one case that runs everywhere: Windows has no subscription, and says so with a system.signal error."""
    vm = start(adopt, tmp_path, IGNORED.replace("System.Signal.Int", "System.Signal.Term"))
    want = "system.signal: signal: not supported on this system" if WINDOWS else "subscribed"
    assert vm.next_line(WAIT_SECONDS) == want
    assert vm.wait(WAIT_SECONDS) == 0
