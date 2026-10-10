import "lib/geometry.agc" as Geo

struct Point
  x: Int
end

def main() -> Void
  here = Geo.Point(x: 1, y: 2)
  mine = Point(x: 3)
  puts(here)
  puts(mine)
  puts(Geo.origin())
  shapes: List[Geo.Shape[String]] = [Geo.Shape.Dot(here), Geo.tag("home", here), Geo.Shape.Nothing, Geo.Shape.Nothing()]
  puts(shapes)
  for s in shapes
    case s
      Geo.Shape.Dot(p) -> puts("dot #{p.x}")
      Geo.Shape.Tagged(name, p) -> puts("#{name} at #{p}")
      Geo.Shape.Nothing -> puts("nothing")
    end
  end
  puts("#{here.y} #{mine.x}")
end
