def price(table: Map[String, Int], item: String) -> Int
  return table[item + "\t\"x\" λ"]
end

def main() -> Void
  prices = {"tea\t\"x\" λ": 3, "jam": 5}
  ids = {1: "one"}
  puts(price(prices, "tea"))
  IO.warn("before #{ids}")
  puts(ids[1])
  puts(price(prices, "milk"))
end
