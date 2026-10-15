import {lex as scan, lex as scan_again, make as build, as as as_text, from as origin} from "lib"
import {Color as Shade, Point as Spot, Maybe as Opt} from "lib"
import {as, from} from "lib"

def main() -> Void
  a = scan("a")
  b = scan_again("b")
  c = build(1)
  d = as_text(2) + origin(3)
  e = as(4) + from(5)
  f = &scan
  g = Shade.Green(1)
  h = Shade.Red
  i = Spot(x: 1, y: 2)
  j: Opt[Spot] = Opt.Some(i)
  case j
    Opt.Some(k) -> puts("#{k}")
    Opt.None -> puts("none")
  end
  l = lex("not bound")
end
