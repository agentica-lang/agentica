import Plane from "lib/plane"
import Geometry from "lib/geometry"
import Measure from "lib/measure"

def label(shape: Plane.Shape[String]) -> String
  case shape
    Plane.Shape.Dot(p) -> return "dot #{p.x}"
    Geometry.Shape.Tagged(name, p) -> return "#{name} at #{Geometry.describe(p)}"
    Plane.Shape.Nothing -> return "nothing"
  end
end

def main() -> Void
  here: Geometry.Point = Plane.Point(x: 1, y: 2)
  moved = here.with(x: 5)
  puts(label(Plane.tag("home", here)))
  puts(label(Plane.Shape.Dot(moved)))
  puts(label(Plane.Shape.Nothing))
  puts(Geometry.describe(Plane.origin()))
  wide: Measure.Rect = Plane.Rect(w: 4, h: 3)
  puts(Plane.area(wide) == Measure.area(wide))
  measure: Fn[Measure.Rect, Int] = &Plane.area
  puts(measure.call(wide))
  puts([wide, Plane.Rect(w: 2, h: 6)].map(&Plane.area))
  case Plane.fit(wide, 12)
    Measure.Fit.Tight -> puts("tight")
    Plane.Fit.Loose(extra) -> puts("loose by #{extra}")
  end
end
