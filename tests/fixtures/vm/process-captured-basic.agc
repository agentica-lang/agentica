def main() -> Void
  here = Process.spawn_captured("pwd", [], Process.Options(timeout_ms: 60000)).unwrap!
  cwd = Process.spawn_captured("pwd", [], Process.Options(chdir: Path.cwd().unwrap!, timeout_ms: 60000)).unwrap!
  puts(Process.output(here, 60000).unwrap!.stdout == Process.output(cwd, 60000).unwrap!.stdout)
  Process.close(here)
  Process.close(cwd)
  IO.inspect(Process.spawn_captured("./sh", ["-c", "echo ran"], Process.Options(chdir: "/bin", timeout_ms: 60000)))
  IO.inspect(Process.spawn_captured("sh", [], Process.Options(chdir: "/no-such-directory", timeout_ms: 60000)))
  IO.inspect(Process.spawn_captured("sh", [], Process.Options(chdir: "", timeout_ms: 60000)))
  p = Process.spawn_captured("sh", ["-c", "echo one; echo two; echo three; echo oops >&2; exit 3"], Process.Options(timeout_ms: 60000)).unwrap!
  IO.inspect(Process.read_line(p, 60000))
  IO.inspect(Process.output(p, 60000))
  IO.inspect(Process.output(p, 60000))
  IO.inspect(Process.read_line(p, 60000))
  IO.inspect(Process.wait(p, 60000))
  Process.close(p)
  IO.inspect(Process.output(p, 60000))
  plain = Process.spawn("sh", ["-c", "exit 0"], Process.Options(timeout_ms: 60000)).unwrap!
  IO.inspect(Process.output(plain, 60000))
  Process.close(plain)
end
