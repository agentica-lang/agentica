# Type.values lists the variants of an enum without payloads, Type.parse reads one from its name, and value.name is the
# bare name of the variant of any enum value.
enum Color
  Red
  Green
  Blue
end

enum Shape
  Dot
  Circle(Int)
  Line(Int, Int)
end

def label(color: Color) -> String = color.name

def main() -> Void
  puts(Color.values.map(&label).join(","))
  puts(Color.values.size)
  puts(Color.values.inspect)

  puts(Shape.Dot.name)
  puts(Shape.Circle(3).name)
  puts(Shape.Line(1, 2).name)

  puts(Color.parse("Green").unwrap!.inspect)
  puts(Color.parse("green").message)
  puts(Color.parse("a\"b\n").message)
  case Color.parse("Blue")
    ok(color) -> puts(label(color))
    error(e) -> puts(e.message)
  end
  puts(Color.parse(text: "Red").unwrap!.name)
  case Color.parse("none")
    ok(_) -> puts("found")
    error(e) -> puts(e.kind)
  end

  puts(System.Signal.values.size)
  puts(System.Signal.parse("Hup").unwrap!.name)
  puts(System.Signal.parse("Nope").message)

  every = Color.values.all? do |color: Color| Color.parse(color.name).unwrap! == color end
  puts(every)
end
