def main() -> Void
  p = Process.spawn_captured("head", ["-c", "2097152", "/dev/zero"], ".", 60000).unwrap!
  IO.inspect(Process.read_line(p, 60000))
  IO.inspect(Process.read_bytes(p, 0, 60000))
  out = Process.output(p, 60000).unwrap!
  puts("stdout #{out.stdout.length}, stderr #{out.stderr.length}, truncated #{out.truncated}")
  IO.inspect(Process.wait(p, 60000))
  Process.close(p)
end
