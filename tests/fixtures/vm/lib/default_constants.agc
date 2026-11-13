# The constants of the defaults below. SHIPPED is private and EMPTY, MODE and BASE are not literals: a caller in another
# file leaves the argument out and still gets the value, because the default is the value written where it is declared.
LIMIT = 7
LABEL = "anon"

EMPTY: List[Int] = []
MODE = Mode.Safe
BASE = Options()

enum Mode
  Fast
  Safe
end

struct Options
  size: Int = LIMIT
  label: String = LABEL
  mode: Mode = MODE
  items: List[Int] = EMPTY
end

def describe(limit: Int = LIMIT, shipped: Int = SHIPPED, items: List[Int] = EMPTY, mode: Mode = MODE) -> String
  return "#{limit} #{shipped} #{items.size} #{mode}"
end

def size_of(options: Options = BASE) -> Int
  return options.size
end

private

SHIPPED = -3
