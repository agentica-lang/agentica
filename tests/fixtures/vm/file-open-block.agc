def at(dir: String, name: String) -> String
  return Path.join([dir, name]).unwrap!
end

# The block's value is the call's Result; the file is closed when the call returns, so its writes are on disk.
def write_lines(path: String, lines: List[String]) -> Result[Int]
  return File.open(path, "write", 60000) do |f|
    for line in lines
      try File.write(f, "#{line}\n", 60000)
    end
    ok(lines.size)
  end
end

# The Result type comes from the body: try works in the block, and a failed try is the call's error.
def first_two(path: String) -> Result[String]
  return File.open(path) do |f|
    a = try File.read_line(f)
    if a == "stop"
      return error("stopped at the first line")
    end

    b = try File.read_line(f)
    ok("#{a}+#{b}")
  end
end

def main() -> Void
  dir: String = System.args()[0]
  notes = at(dir, "notes.txt")
  puts("write: #{write_lines(notes, ["alpha", "beta"])}")
  puts("read back after the block: #{File.read_text(notes, 60000).unwrap!.inspect}")

  puts("two lines: #{first_two(notes)}")
  File.write_text(notes, "stop\nnever\n", 60000).unwrap!
  puts("early return: #{first_two(notes)}")
  File.write_text(notes, "only\n", 60000).unwrap!
  puts("failed try: #{first_two(notes)}")

  # The expected type of the call gives the block's Result type.
  sizes: Result[List[Int]] = File.open(notes, "read", 60000) do |f| ok([(try File.read_line(f, 60000)).size]) end
  puts("expected type: #{sizes}")

  # A handle that leaves the block is closed.
  kept = File.open(notes) do |f| ok(f) end
  handle = kept.unwrap!
  puts("handle after an ok block: #{File.read_line(handle, 60000)}")
  # The close after an error block still flushes the writes.
  failed: Result[Int] = File.open(notes, "write") do |f|
    try File.write(f, "kept\n")
    error("the block failed")
  end
  puts("error block: #{failed}")
  puts("written before the error: #{File.read_text(notes, 60000).unwrap!.inspect}")

  copy = at(dir, "copy.txt")
  File.write_text(notes, "one\ntwo\n", 60000).unwrap!
  nested = File.open(copy, "write") do |out|
    File.open(notes) do |source|
      count = 0
      line = File.read_line(source)
      while line.ok?
        try File.write(out, line.unwrap!.upcase + "\n")
        count += 1
        line = File.read_line(source)
      end
      ok(count)
    end
  end
  puts("nested: #{nested}")
  puts("copy: #{File.read_text(copy, 60000).unwrap!.inspect}")

  appended = File.open(copy, "append") do |out|
    try File.write(out, "three\n")
    ok()
  end
  puts("append: #{appended} #{File.read_text(copy, 60000).unwrap!.inspect}")

  missing = File.open(at(dir, "missing.txt")) do |_|
    puts("never printed: the block does not run when the open fails")
    ok(1)
  end
  puts("missing file: #{!missing.ok?}")
  puts("timeout: #{File.open(notes, "read", 0) do |_| ok(1) end}")
end
