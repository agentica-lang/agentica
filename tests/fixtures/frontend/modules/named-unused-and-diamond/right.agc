import Lib from "lib"
import {lex as measure} from "lib"

export def right() -> Lib.Point
  return Lib.Point(x: measure("r"), y: 0)
end
