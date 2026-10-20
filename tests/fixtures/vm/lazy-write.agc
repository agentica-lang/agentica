# Lazy.write_lines: each item and a line feed into a file, created or truncated. The file opens before the first item
# is pulled and is flushed and closed before the terminal returns, on every path. tests/test_vm_lazy_io.py watches the
# opens and closes in the trace.
def at(dir: String, name: String) -> String
  return Result.unwrap!(Path.join([dir, name]))
end

def back(path: String) -> String
  return File.read_text(path, 60000).unwrap!.inspect
end

def number(text: String) -> Result[Int]
  return text.to_i
end

def main() -> Void
  dir: String = System.args()[0]
  out = at(dir, "out.txt")
  puts("three lines: #{["a", "bc", ""].lazy.write_lines(out, 60000)} #{back(out)}")
  puts("truncated: #{["new"].lazy.write_lines(out, 60000)} #{back(out)}")
  puts("no items, an empty file: #{(1..0).lazy.map do |n| "#{n}" end.write_lines(out, 60000)} #{back(out)}")
  puts("an endless source with take: #{Lazy.produce(1) do |n| n * 2 end.map do |n| "#{n}" end.take(4).write_lines(out, 60000)} #{back(out)}")
  copy = at(dir, "copy.txt")
  puts("a copy through steps: #{File.foreach(out, 1024, 60000).filter do |line| line != "4" end.write_lines(copy, 60000)} #{back(copy)}")
  big = List.repeat("x", 70000).join("")
  puts("lines past the buffer: #{[big, big, "end"].lazy.write_lines(out, 60000)} #{File.read_text(out, 60000).unwrap!.length}")
  failed = ["1", "2", "x", "4"].lazy.map do |s| "#{try number(s) * 10}" end.write_lines(out, 60000)
  puts("a failed try keeps what was written: #{failed} #{back(out)}")
  mib = List.repeat(List.repeat("y", 1024).join(""), 1024).join("")
  puts("a line over 1 MiB: #{["ok", mib + "y"].lazy.write_lines(out, 60000)} #{back(out)}")
  puts("a missing directory: #{["a"].lazy.write_lines(at(dir, "missing/out.txt"), 60000).ok?}")
  puts("a directory: #{["a"].lazy.write_lines(dir, 60000).ok?}")
  puts("a bad timeout: #{["a"].lazy.write_lines(out, 0)}")
  calls = Lazy.produce(0) do |n|
    puts("  never called")
    n + 1
  end
  puts("a failed open pulls nothing: #{calls.map do |n| "#{n}" end.write_lines(dir, 60000).ok?}")
end
