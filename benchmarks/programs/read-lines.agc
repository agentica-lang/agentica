def scale() -> Int
  return 1
end

# File.write of 300000 lines, then File.read_line over them: a line that the handle's buffer holds costs no I/O job, so
# the reads are a loop, not one hop to the I/O thread per line. The time is both phases; the writes are buffered.
def main() -> Void
  lines = 300000 * scale()
  directory = System.env("TMPDIR").unwrap_or("/tmp")
  path = Path.join([directory, "agentica-bench-read-lines-#{System.pid}.txt"]).unwrap!
  out = File.open(path, "write").unwrap!
  i = 0
  while i < lines
    File.write(out, "|-DeclRefExpr 0x#{i} <line:#{i}:#{i % 80}> 'int' lvalue Var 'x'\n").unwrap!
    i += 1
  end
  File.close(out).unwrap!
  input = File.open(path, "read").unwrap!
  count = 0
  bytes = 0
  while true
    case File.read_line(input)
      ok(line) ->
        count += 1
        bytes += line.length
      error(_) -> break
    end
  end
  File.close(input).unwrap!
  Path.remove(path).unwrap!
  puts("read-lines #{count} #{bytes}")
end
