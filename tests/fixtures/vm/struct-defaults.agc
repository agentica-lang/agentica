import Lib from "lib/struct_defaults_lib"

struct Point
  x: Int = 0
  y: Int
end

struct Box
  width: Int = 1
  height: Int = 2
  depth: Int = 3
end

def volume(b: Box = Box()) -> Int
  return b.width * b.height * b.depth
end

def main() -> Void
  puts(Lib.describe(Lib.Options(name: "plain")))
  puts(Lib.describe(Lib.Options(name: "given", retries: 9, tags: ["a"], level: Lib.Level.Loud)))
  puts(Point(y: 5).inspect)
  puts(Point(y: 5, x: 4).inspect)
  puts(Box().inspect)
  puts(Box(depth: 7).inspect)
  puts(Box(height: 0, width: 0).inspect)
  puts(Box(depth: 7).with(width: 8).inspect)
  # Each construction builds its own default list, and a given field is evaluated once, in source order.
  first = Lib.Options(name: "a")
  second = first.with(tags: first.tags.push("b"))
  puts(first.tags.size)
  puts(second.tags.size)
  # A parameter default that builds a struct with no arguments.
  puts(volume())
  puts(volume(Box(depth: 1)))
  puts(Lib.limits_text())
  puts(Lib.limits_text(Lib.Limits(count: 1)))
end
