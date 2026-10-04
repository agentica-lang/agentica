def main() -> Void
  stock: Map[String, Int] = {"apple": 3, "pear": 0}
  stock = Map.put(stock, "kiwi", 7)
  for name in Map.keys(stock)
    if stock[name] > 0
      puts(name)
    end
  end
end
