def main() -> Void
  root = Process.spawn_captured("/bin/pwd", [], "/", 60000).unwrap!
  IO.inspect(Process.output(root, 60000))
  Process.close(root)
  here = Process.spawn_captured("/bin/pwd", [], ".", 60000).unwrap!
  cwd = Process.spawn_captured("/bin/pwd", [], Path.cwd().unwrap!, 60000).unwrap!
  puts(Process.output(here, 60000).unwrap!.stdout == Process.output(cwd, 60000).unwrap!.stdout)
  Process.close(here)
  Process.close(cwd)
  IO.inspect(Process.spawn_captured("./sh", ["-c", "echo ran"], "/bin", 60000))
  IO.inspect(Process.spawn_captured("sh", [], "/no-such-directory", 60000))
  IO.inspect(Process.spawn_captured("sh", [], "", 60000))
  p = Process.spawn_captured("sh", ["-c", "echo one; echo two; echo three; echo oops >&2; exit 3"], ".", 60000).unwrap!
  IO.inspect(Process.read_line(p, 60000))
  IO.inspect(Process.output(p, 60000))
  IO.inspect(Process.output(p, 60000))
  IO.inspect(Process.read_line(p, 60000))
  IO.inspect(Process.wait(p, 60000))
  Process.close(p)
  IO.inspect(Process.output(p, 60000))
  plain = Process.spawn("sh", ["-c", "exit 0"], 60000).unwrap!
  IO.inspect(Process.output(plain, 60000))
  Process.close(plain)
end
