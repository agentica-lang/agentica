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
  resource Counter
  def add(a: Int, b: Id) -> Int
  def area(s: Shape) -> Int
  def points(n: Int, rows: Map[String, List[Optional[Point]]]) -> Result[List[Point]]
  def nothing?() -> Void
  compute def crunch(n: Int) -> Int
  def counter(id: Int) -> Counter
  compute def counters(n: Int) -> Result[List[Counter]]
end

def main() -> Void
  puts(add(1, 2) + area(Shape.Dot) + crunch(3))
  puts(points(2, {}).ok?)
  nothing?()
  Native.close(counter(1))
  puts(counters(2).ok?)
end
