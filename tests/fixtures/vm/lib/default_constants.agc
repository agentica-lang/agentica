# The constants of the defaults below. SHIPPED is private and EMPTY, MODE and BASE are not literals: a caller in another
# file leaves the argument out and still gets the value, because the default is the value written where it is declared.
export LIMIT = 7
export LABEL = "anon"
SHIPPED = -3
export EMPTY: List[Int] = []
export MODE = Mode.Safe
export BASE = Options()

export enum Mode
  Fast
  Safe
end

export struct Options
  size: Int = LIMIT
  label: String = LABEL
  mode: Mode = MODE
  items: List[Int] = EMPTY
end

export def describe(limit: Int = LIMIT, shipped: Int = SHIPPED, items: List[Int] = EMPTY, mode: Mode = MODE) -> String
  return "#{limit} #{shipped} #{items.size} #{mode}"
end

export def size_of(options: Options = BASE) -> Int
  return options.size
end
