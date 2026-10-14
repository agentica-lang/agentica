def lines(path: String, buffer: Int) -> Result[Int]
  r = File.each_line(path, buffer, 60000) do |line|
    ok()
  end
  case r
    ok(_) -> return ok(buffer)
    error(e) -> return error(e)
  end
end

def read(buffer: Int) -> Result[Int]
  return lines(Result.unwrap!(Path.join([System.args()[0], "lines.txt"])), buffer)
end

def read_missing(buffer: Int) -> Result[Int]
  return lines(Result.unwrap!(Path.join([System.args()[0], "missing.txt"])), buffer)
end

def report(label: String, r: Result[Int]) -> Void
  case r
    ok(n) -> puts("#{label}: ok #{n}")
    error(e) -> puts("#{label}: #{e}")
  end
end

def main() -> Void
  Result.unwrap!(File.write_text(Result.unwrap!(Path.join([System.args()[0], "lines.txt"])), "a\nb\n", 60000))
  report("buffer 1024", Task.await(Task.spawn(&read, 1024)))
  report("buffer 16777216", Task.await(Task.spawn(&read, 16777216)))
  report("buffer 1023", Task.await(Task.spawn(&read, 1023)))
  report("buffer 16777217", Task.await(Task.spawn(&read, 16777217)))
  report("buffer 0", Task.await(Task.spawn(&read, 0)))
  report("buffer -1", Task.await(Task.spawn(&read, -1)))
  report("missing file, buffer 4096", Task.await(Task.spawn(&read_missing, 4096)))
  report("missing file, buffer 10", Task.await(Task.spawn(&read_missing, 10)))
end
