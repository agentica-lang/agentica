def drive_free(result: Result[String], drive: String) -> Void
  if result.ok?
    IO.inspect(Result.unwrap!(result).replace(drive, "<drive>"))
  else
    IO.inspect(result)
  end
end

def main() -> Void
  cwd = Result.unwrap!(Path.cwd())
  drive = cwd.slice(0, 2)
  for parts in [["//a", "b"], ["//a/", "b"], ["//a/b//", "c"], ["//a", "b", "c"]]
    IO.inspect(Path.join(parts))
  end
  for path in ["/", "/a/b/", "/a/b/.", "/a/b/..", "/a/../..", "//a//b", "/a/./b/../c", "/..", "/a/b/../", "/a/b//.", "/a/b/...", "/tmp/./", "/a/b/c/../../x/", "/a/b/../../../../c", "/é/./λ"]
    drive_free(Path.resolve(path), drive)
  end
  IO.inspect(cwd.ends_with?("/"))
  IO.inspect(Result.unwrap!(Path.resolve("x/../y")) == cwd + "y")
end
