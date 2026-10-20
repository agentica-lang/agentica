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
  deep = at(dir, "a/b/c")
  Dir.mkdir(deep, 60000)
  file = at(deep, "f.txt")
  File.write_text(file, "data", 60000)
  show(base, Path.real(at(dir, "a/missing/..")))
  show(base, Path.real(at(file, "x")))
  show(base, Path.real("/"))
  show(base, Path.real("/.."))
end
