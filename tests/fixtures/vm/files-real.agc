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
  nul = String.from_code(0)
  deep = at(dir, "a/b/c")
  Dir.mkdir(deep, 60000)
  file = at(deep, "f.txt")
  File.write_text(file, "data", 60000)
  show(base, Path.real(dir))
  show(base, Path.real(dir + "/"))
  show(base, Path.real(deep))
  show(base, Path.real(deep + "/"))
  show(base, Path.real(file))
  show(base, Path.real(dir + "/a/b/../b/./c"))
  show(base, Path.real(dir + "//a///b//c/f.txt"))
  show(base, Path.real(dir + "/a/b/../.."))
  show(base, Path.real(at(dir, "missing")))
  show(base, Path.real(at(dir, "a/missing/..")))
  show(base, Path.real(file + "/"))
  show(base, Path.real(at(file, "x")))
  show(base, Path.real("/"))
  show(base, Path.real("/.."))
  show(base, Path.real(""))
  show(base, Path.real(dir + nul))
  cwd = Result.unwrap!(Path.cwd())
  here = cwd.slice(0, cwd.length - 1)
  IO.inspect(Path.real(".").unwrap_or("") == here)
  IO.inspect(Path.real("./").unwrap_or("") == here)
  IO.inspect(Path.real("./.").unwrap_or("") == here)
  winding = dir
  i = 0
  while i < 1000
    winding = winding + "/a/.."
    i += 1
  end
  IO.inspect(winding.length > 4096)
  show(base, Path.real(winding))
  name = "x"
  j = 0
  while j < 7
    name = name + name
    j += 1
  end
  long = dir
  k = 0
  while k < 28
    long = long + "/" + name.slice(0, 120)
    k += 1
  end
  IO.inspect(Path.real(long).ok?)
  Dir.mkdir(long, 60000)
  IO.inspect(Result.unwrap!(Path.real(long)).length - base.length == long.length - dir.length)
  IO.inspect(Path.real(long + "/" + name.slice(0, 120) + "/" + long).ok?)
end
