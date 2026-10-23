enum Mode
  Fast
  Safe
end

struct Options
  name: String
  retries: Int = 3
  ratio: Float = -0.5
  tags: List[String] = []
  meta: Map[String, Int] = {}
  mode: Mode = Mode.Safe
end

def main() -> Void
  puts(Options(name: "a").inspect)
  puts(Options(name: "b", retries: 1, mode: Mode.Fast).inspect)
end
