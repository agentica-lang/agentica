def main() -> Void
  quiet = Process.spawn_captured("sh", ["-c", "head -c 2097152 /dev/zero >&2; exec sleep 60"], ".", 60000).unwrap!
  IO.inspect(Process.read_line(quiet, 60000))
  IO.inspect(Process.read_bytes(quiet, 0, 60000))
  Process.close(quiet)
  done = Process.spawn_captured("sh", ["-c", "head -c 2097152 /dev/zero >&2; echo done"], ".", 60000).unwrap!
  IO.inspect(Process.wait(done, 60000))
  IO.inspect(Process.read_bytes(done, 0, 60000))
  out = Process.output(done, 60000).unwrap!
  puts("stdout #{out.stdout.inspect}, stderr #{out.stderr.length}, truncated #{out.truncated}")
  Process.close(done)
end
