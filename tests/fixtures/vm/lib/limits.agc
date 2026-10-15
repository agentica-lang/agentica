import {BASE} from "limits_base"

export TOP = BASE * 2
export NAMES = ["x", "y", "z"]
export STARTS = Set.new(NAMES)
export ZERO = 0

export WINDOW = Window(low: ZERO, high: TOP)

export struct Window
  low: Int
  high: Int
end

export def top() -> Int
  return TOP
end
