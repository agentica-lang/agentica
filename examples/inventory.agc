def main() -> Void
  stock: Map[String, Int] = {"apple": 3, "pear": 0}
  stock = stock.put("kiwi", 7)
  for name in stock.keys
    if stock[name] > 0
      puts(name)
    end
  end
end
