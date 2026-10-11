def main() -> Void
  nul = String.from_code(0)
  IO.inspect(Path.join([]))
  for parts in [["a"], ["a", "b"], ["/a", "b"], ["a/", "b"], ["a//", "b"], ["a", "b//"], ["//a", "b"], ["//a/", "b"], ["//a//b", "c"], ["///a", "b"], ["//", "b"], ["//a/b//", "c"], ["//a", "b", "c"], [".", ".."], ["x/", "y/"], ["/"], ["é", "λ 𝔸"]]
    IO.inspect(Path.join(parts))
  end
  for parts in [["a", "/b"], ["a", "/b", ""], ["a", "", "/b"], ["", "b"], ["a" + nul], ["/", "/"]]
    IO.inspect(Path.join(parts))
  end
  for path in ["/", "/a/b/", "/a/b/.", "/a/b/..", "/a/../..", "//a//b", "/a/./b/../c", "/..", "/a/b/../", "/a/b//.", "/a/b/...", "/tmp/./", "/a/b/c/../../x/", "/a/b/../../../../c", "/é/./λ"]
    IO.inspect(Path.resolve(path))
  end
  IO.inspect(Path.resolve(""))
  IO.inspect(Path.resolve("a" + nul + "b"))
  cwd = Result.unwrap!(Path.cwd())
  IO.inspect(cwd.ends_with?("/"))
  IO.inspect(Result.unwrap!(Path.resolve(".")) == cwd)
  IO.inspect(Result.unwrap!(Path.resolve("x/../y")) == cwd + "y")
  long = "x"
  i = 0
  while i < 9
    long = long + long
    i += 1
  end
  IO.inspect(Path.join(["a", "/" + long]))
  IO.inspect(Path.resolve(long + nul))
  IO.inspect(Path.resolve(long.slice(0, 250) + nul))
  IO.inspect(Path.resolve(long.slice(0, 251) + nul))
  IO.inspect(Path.resolve("é".slice(0, 1) + long.slice(0, 260) + nul))
end
