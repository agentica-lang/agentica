# A channel line that the child's exit cuts off (no LF at the end) is an error, never a line. A line that ends in LF
# before the exit is read as usual, and so is the end of input after it.
def ask(script: String) -> Void
  p = Process.spawn_channel("sh", ["-c", script], Process.Options(timeout_ms: 5000)).unwrap!
  first = Process.channel_read_line(p, 5000)
  if first.ok?
    puts("ok #{first.unwrap!.length}")
  else
    puts("error #{first.message}")
  end

  puts(Process.channel_read_line(p, 5000).inspect)
  Process.close(p)
end

def main() -> Void
  # Whole line, then the exit.
  ask("printf 'whole\\n' >&3")
  # Bytes without an LF, then the exit.
  ask("printf 'cut' >&3")
  # A million bytes without an LF, as in a send that was refused after its write began.
  ask("head -c 1000000 /dev/zero | tr '\\0' x >&3")
  # The child dies in the middle of a line.
  ask("printf 'cut' >&3; kill -KILL $$")
end
