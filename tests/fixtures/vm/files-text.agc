def at(dir: String, name: String) -> String
  return Result.unwrap!(Path.join([dir, name]))
end

def main() -> Void
  dir: String = System.args()[0]
  notes = at(dir, "notes.txt")
  IO.inspect(File.write_text(notes, "alpha\n", 60000))
  IO.inspect(File.append_text(notes, "βeta\r\n", 60000))
  IO.inspect(File.append_text(at(dir, "fresh.txt"), "", 60000))
  IO.inspect(File.read_text(notes, 60000))
  IO.inspect(File.write_text(notes, "short", 60000))
  IO.inspect(File.read_text(notes, 60000))
  IO.inspect(File.read_text(at(dir, "fresh.txt"), 60000))
  info = Result.unwrap!(File.stat(notes, 60000))
  puts("#{info.kind} #{info.size_bytes} #{info.modified_seconds > 1000000000}")
  folder = Result.unwrap!(File.stat(dir, 60000))
  puts("#{folder.kind} #{folder.size_bytes}")
  IO.inspect(File.stat(at(dir, "missing"), 60000))
  nested = at(at(at(dir, "a"), "b"), "c")
  IO.inspect(Dir.mkdir(nested, 60000))
  IO.inspect(Dir.mkdir(nested, 60000))
  IO.inspect(Dir.mkdir(at(dir, "a//b/./d/"), 60000))
  IO.inspect(Dir.mkdir(notes, 60000))
  for name in ["zeta", "Alpha", "émile", "_x", "10", "9"]
    File.write_text(at(dir, name), name, 60000)
  end
  IO.inspect(Dir.list(dir, 60000))
  IO.inspect(Dir.list(at(dir, "a"), 60000))
  IO.inspect(Dir.list(at(dir, "a/b/"), 60000))
  IO.inspect(File.read_text(at(dir, "émile"), 60000))
  IO.inspect(File.read_text(at(at(dir, "a"), "../notes.txt"), 60000))
  IO.inspect(Result.unwrap!(Path.resolve(at(dir, "a/b/../../notes.txt"))) == notes)
end
