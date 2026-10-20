def main() -> Void
  for parts in [["//a", "b"], ["//a/", "b"], ["//a/b//", "c"], ["//a", "b", "c"]]
    IO.inspect(Path.join(parts))
  end
  for path in ["/", "/a/b/", "/a/b/.", "/a/b/..", "/a/../..", "//a//b", "/a/./b/../c", "/..", "/a/b/../", "/a/b//.", "/a/b/...", "/tmp/./", "/a/b/c/../../x/", "/a/b/../../../../c", "/é/./λ"]
    IO.inspect(Path.resolve(path))
  end
  cwd = Result.unwrap!(Path.cwd())
  IO.inspect(cwd.ends_with?("/"))
  IO.inspect(Result.unwrap!(Path.resolve(".")) == cwd)
  IO.inspect(Result.unwrap!(Path.resolve("x/../y")) == cwd + "y")
end
