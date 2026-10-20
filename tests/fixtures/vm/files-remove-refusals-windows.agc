def main() -> Void
  dir: String = System.args()[0]
  tree = Result.unwrap!(Path.join([dir, "tree"]))
  Dir.mkdir(Result.unwrap!(Path.join([tree, "a/b/c"])), 60000)
  top = Result.unwrap!(Path.join([tree, "top.txt"]))
  File.write_text(top, "t", 60000)
  IO.inspect(Path.remove(Result.unwrap!(Path.join([top, "x"])), 60000))
  IO.inspect(Path.remove(Result.unwrap!(Path.join([tree, "a/.."])), 60000))
  IO.inspect(Path.remove(Result.unwrap!(Path.join([tree, "a/b/c/"])) + "/.", 60000))
  IO.inspect(File.lstat(Result.unwrap!(Path.join([tree, "a/b/c"])), 60000).ok?)
  IO.inspect(Path.remove(tree, 60000))
end
