import Geo from "lib/geometry"
import {Point, Shape, origin, tag, describe as describe_point} from "lib/geometry"
import {Rect, Fit, fit, area, describe as describe_rect} from "lib/measure"
import {Rect as Box} from "lib/measure"

def label(shape: Shape[String]) -> String
  case shape
    Shape.Dot(p) -> return "dot #{p.x}"
    Shape.Tagged(name, p) -> return "#{name} at #{describe_point(p)}"
    Shape.Nothing -> return "nothing"
  end
end

def room_text(f: Fit) -> String
  case f
    Fit.Tight -> return "tight"
    Fit.Loose(extra) -> return "loose by #{extra}"
  end
end

def main() -> Void
  here = Point(x: 1, y: 2)
  moved = here.with(x: 5)
  both = Geo.tag("both", Geo.origin())
  puts(label(tag("home", here)))
  puts(label(Shape.Dot(moved)))
  puts(label(Shape.Nothing))
  puts(label(both))
  puts(describe_point(origin()))
  puts(Geo.describe(here) == describe_point(here))
  wide = Rect(w: 4, h: 3)
  same: Box = Box(w: 2, h: 6).with(h: 3)
  puts(describe_rect(wide))
  puts(describe_rect(same.with(w: 1)))
  puts(area(wide))
  puts(room_text(fit(wide, 12)))
  puts(room_text(Fit.Loose(2)))
  puts(room_text(fit(wide, 20)))
  measure: Fn[Rect, Int] = &area
  puts(measure.call(wide))
  areas = [wide, same].map(&area)
  puts(areas)
  puts([wide, same].map do |r: Rect| describe_rect(r) end)
  puts(wide |> area())
end
