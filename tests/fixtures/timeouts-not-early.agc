# Short timeouts, measured with Time.monotonic_ns, while a task keeps the scheduler turning: a busy loop runs its
# timers often, so a timer counted from a lagging clock would fire early. A socket read or accept waits on the event
# loop's timer and must never end before its timeout. Task.sleep and a channel receive wait on the scheduler's clock,
# which counts whole milliseconds, so they may end up to 1 ms before it.

def spin(stop: Channel[Int]) -> Int
  turns = 0
  while Channel.empty?(stop)
    Task.sleep(0)
    turns = turns + 1
  end
  return turns
end

def check(name: String, timeout_ms: Int, allowed_ms: Int, started: Int, timed_out: Bool) -> Int
  took = Time.monotonic_ns() - started
  if not timed_out
    puts("#{name} #{timeout_ms} ms did not time out")
    return 1
  end
  if took < (timeout_ms - allowed_ms) * 1000000
    puts("#{name} #{timeout_ms} ms ended after #{took} ns")
    return 1
  end
  return 0
end

def network(listener: Listener, timeout_ms: Int) -> Int
  client = TCP.connect("127.0.0.1", TCP.local_port(listener), 5000).unwrap!
  server = TCP.accept(listener, 5000).unwrap!
  started = Time.monotonic_ns()
  bad = check("read", timeout_ms, 0, started, !TCP.recv_bytes(client, 16, timeout_ms).ok?)
  TCP.close(server)
  started = Time.monotonic_ns()
  return bad + check("accept", timeout_ms, 0, started, !TCP.accept(listener, timeout_ms).ok?)
end

def main() -> Void
  stop: Channel[Int] = Channel.new(1)
  spinner = Task.spawn(&spin, stop)
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  silent: Channel[Int] = Channel.new(1)
  bad = 0
  for _round in 0...6
    for timeout_ms in [0, 1, 2, 3, 5, 10]
      if timeout_ms > 0
        bad = bad + network(listener, timeout_ms)
      end
      started = Time.monotonic_ns()
      bad = bad + check("recv", timeout_ms, 1, started, !Channel.recv(silent, timeout_ms).ok?)
      started = Time.monotonic_ns()
      Task.sleep(timeout_ms)
      bad = bad + check("sleep", timeout_ms, 1, started, true)
    end
  end
  Channel.send(stop, 1, 5000).unwrap!
  Task.await(spinner)
  if bad == 0
    puts("ok")
  end
end
