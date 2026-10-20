def at(dir: String, name: String) -> String
  return Result.unwrap!(Path.join([dir, name]))
end

def main() -> Void
  dir: String = System.args()[0]
  file = at(dir, "file.txt")
  File.write_text(file, "data", 60000)
  IO.inspect(File.read_text(file + "/", 60000))
  IO.inspect(File.write_text(at(file, "x"), "x", 60000))
  IO.inspect(Dir.mkdir(at(at(file, "sub"), "deeper"), 60000))
  IO.inspect(Dir.mkdir(dir + "/file.txt//sub", 60000))
end
