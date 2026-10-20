def at(dir: String, name: String) -> String
  return Result.unwrap!(Path.join([dir, name]))
end

# What a mkdir through a file says is the same on Linux and macOS in the reason only: the path it names differs.
def reason(result: Result[Void]) -> String
  lines = Result.message(result).split("\n")
  return lines[lines.length - 1]
end

def main() -> Void
  dir: String = System.args()[0]
  file = at(dir, "file.txt")
  File.write_text(file, "data", 60000)
  IO.inspect(File.read_text(file + "/", 60000))
  IO.inspect(File.write_text(at(file, "x"), "x", 60000))
  IO.inspect(reason(Dir.mkdir(at(at(file, "sub"), "deeper"), 60000)))
  IO.inspect(reason(Dir.mkdir(dir + "/file.txt//sub", 60000)))
end
