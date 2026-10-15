LIMIT = 4
## The largest value.
export MAX = LIMIT + 1
export NAMES = ["a", "b"]
export LEVELS: Map[String, Int] = {"x": 1}
HIDDEN = 5
export CONFIG = Config(port: 80)

export struct Config
  port: Int
end

export def double(x: Int) -> Int
  return x * 2
end
