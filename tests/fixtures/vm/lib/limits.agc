import {BASE} from "limits_base"

TOP = BASE * 2
NAMES = ["x", "y", "z"]
STARTS = Set.new(NAMES)
ZERO = 0

WINDOW = Window(low: ZERO, high: TOP)

struct Window
  low: Int
  high: Int
end

def top() -> Int
  return TOP
end
