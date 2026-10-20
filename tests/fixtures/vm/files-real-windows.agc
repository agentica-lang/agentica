def at(dir: String, name: String) -> String
  return Result.unwrap!(Path.join([dir, name]))
end

def show(base: String, result: Result[String]) -> Void
  if result.ok?
    IO.inspect(Result.unwrap!(result).replace(base, "<root>"))
  else
    IO.inspect(result)
  end
end

def main() -> Void
  dir: String = System.args()[0]
  base = Result.unwrap!(Path.real(dir))
  drive = base.slice(0, 3)
  deep = at(dir, "a/b/c")
  Dir.mkdir(deep, 60000)
  file = at(deep, "f.txt")
  File.write_text(file, "data", 60000)
  show(base, Path.real(at(dir, "a/missing/..")))
  show(base, Path.real(file + "/"))
  show(base, Path.real(at(file, "x")))
  IO.inspect(Path.real("/").unwrap_or("") == drive)
  IO.inspect(Path.real("/..").unwrap_or("") == drive)
  name = String.join(List.repeat("x", 100), "")
  long = dir
  k = 0
  while k < 4
    long = long + "/" + name
    k += 1
  end
  # Both lines change once agentica.exe has a longPathAware manifest, and then the answer depends on the
  # LongPathsEnabled setting. Today the mkdir fails, so Path.real fails because the folder is missing;
  # tests/test_filesystem.py makes the folder with a \\?\ prefix and asks Path.real for it.
  IO.inspect(Dir.mkdir(long, 60000).ok?)
  IO.inspect(Path.real(long).ok?)
end
