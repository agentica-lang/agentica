def main() -> Void
  IO.inspect(Process.spawn_captured("/bin/pwd", [], "/", 60000))
  find = System.env("SystemRoot").unwrap! + "/System32/findstr.exe"
  root = Process.spawn_captured(find, ["/?"], "/", 60000).unwrap!
  IO.inspect(Process.wait(root, 60000))
  out = Process.output(root, 60000).unwrap!
  IO.inspect(out.stdout.length > 100)
  IO.inspect(out.stderr)
  Process.close(root)
end
