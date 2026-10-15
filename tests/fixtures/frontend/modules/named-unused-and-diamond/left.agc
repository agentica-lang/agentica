import {Point, lex} from "lib"

export def left() -> Point
  return Point(x: lex("l"), y: 0)
end
