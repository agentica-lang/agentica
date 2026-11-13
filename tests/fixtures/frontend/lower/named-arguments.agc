def check(name: String, runs: Int = 100, seed: Int = 0, verbose: Bool = false) -> String
  "#{name} #{runs} #{seed} #{verbose}"
end

def main() -> Void
  puts(check("sort", verbose: true))
  puts(check(seed: 1, name: "map"))
  puts(["a", "b"].join(separator: "-"))
end
