import "a" as A
import "b" as B

struct Both
  a: A.Point
  b: B.Point
end

def main() -> Void
  A.show()
  p = A.Point(x: 3)
  puts(p)
  puts(B.Point(y: 4).inspect)
  puts([A.Shape.Dot(p)].to_s)
  puts({"k": ok(A.Shape.Empty)})
  IO.warn(p)
  IO.warn(JSON.schema(Both))
end

