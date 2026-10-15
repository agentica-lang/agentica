import Lib from "lib"
import {Color, Maybe, Point, lex, make as build} from "lib"
import {Point as Spot} from "lib"
import {twice} from "mid"

struct Holder
  spot: Point
  shade: Color
  maybe: Maybe[Point]
end

enum Wrap
  Item(Point)
  Pair(Color, Maybe[Color])
  End
end

def shade_of(c: Color) -> Result[Point]
  case c
    Color.Red -> return ok(build(1))
    Color.Green(n) -> return ok(Point(x: n, y: n))
  end
end

def unwrap(m: Maybe[Point], fallback: Spot) -> Spot
  case m
    Maybe.Some(p) -> return p
    Maybe.None -> return fallback
  end
end

def main() -> Void
  red = Color.Red
  green = Color.Green(1)
  named = Color.Green(n: 2)
  some = Maybe.Some(build(2))
  none: Maybe[Point] = Maybe.None
  p = Point(x: 1, y: 2)
  q = p.with(x: 3)
  r = lex("abc")
  s = "abc" |> lex()
  f = &lex
  g = &build
  pts: List[Point] = [p, q, twice("a")]
  shades: Map[String, Color] = {"r": red}
  mapped = pts.map do |v: Point| v.x end
  h = Holder(spot: p, shade: green, maybe: some)
  w = Wrap.Pair(red, Maybe.Some(green))
  t = Lib.Point(x: 0, y: 0)
  u = Lib.Color.Red
  v = Lib.lex("x")
  puts("#{lex("abc")} #{red}")
end
