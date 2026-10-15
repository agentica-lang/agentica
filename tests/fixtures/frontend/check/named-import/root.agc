import Geometry from "lib"
import {double, Point as Pt, Shape as Form} from "lib"

def main() -> Void
  p = Pt(x: double(2), y: 3)
  shape = Form.Line(p, Geometry.origin())
  moved = p.with(x: 5)
  case shape
    Form.Dot(d) -> puts(d.x)
    Form.Line(a, b) -> puts(a.x + b.y + moved.x)
  end
end
