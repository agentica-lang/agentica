def main() -> Void
  root = Process.spawn_captured("/bin/pwd", [], Process.Options(chdir: "/", timeout_ms: 60000)).unwrap!
  IO.inspect(Process.output(root, 60000))
  Process.close(root)
end
