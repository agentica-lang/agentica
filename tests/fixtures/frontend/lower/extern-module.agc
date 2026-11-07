type Id = Int

struct Point
  x: Id
  y: Int
end

enum Shape
  Dot
  Circle(Int)
  Rect(Point, Point)
end

extern module "/opt/lib/module demo.so"
  def add(a: Int, b: Id) -> Int
  def area(s: Shape) -> Int
  def points(n: Int, rows: Map[String, List[Optional[Point]]]) -> Result[List[Point]]
  def nothing?() -> Void
  compute def crunch(n: Int) -> Int
end

def main() -> Void
  puts(add(1, 2) + area(Shape.Dot) + crunch(3))
  puts(points(2, {}).ok?)
  nothing?()
end
