def closer(p: Process) -> Int
  start = Time.monotonic_ms()
  Process.close(p)
  puts("closer: closed")
  return Time.monotonic_ms() - start
end

def other(n: Int) -> Void
  puts("other: ran")
end

def main() -> Void
  stubborn = Process.spawn("sh", ["-c", "trap '' TERM; exec sleep 100"], 5000).unwrap!
  a = Task.spawn(&closer, stubborn)
  b = Task.spawn(&other, 0)
  Task.await(b)
  puts("close woken by the exit: #{Task.await(a) < 900}")
  IO.inspect(Process.wait(stubborn, 5000))
  IO.inspect(Process.read_line(stubborn, 5000))
  Process.close(stubborn)

  gone = Process.spawn("sh", ["-c", "exit 3"], 5000).unwrap!
  IO.inspect(Process.wait(gone, 5000))
  Process.close(gone)
  puts("closed after wait")
  IO.inspect(Process.read_line(gone, 5000))
  Process.close(gone)

  quick = Process.spawn("sh", ["-c", "exit 0"], 5000).unwrap!
  Task.sleep(100)
  Process.close(quick)
  puts("closed after exit")

  racing = Process.spawn("sh", ["-c", "exit 0"], 5000).unwrap!
  Process.close(racing)
  puts("closed while running")
  IO.inspect(Process.wait(racing, 5000))
end
