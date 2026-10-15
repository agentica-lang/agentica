import Inv from "lib/inventory"
import Stock from "lib/stock"
import Pad from "pkg/text/pad"

def main() -> Void
  items = [Stock.Item(name: "pen", count: 0), Stock.Item(name: "ink", count: 3)]
  more = Inv.restock(items, 4)
  for item in more
    puts("#{Pad.left(item.name, 6)}: #{Stock.level(item)}")
  end
  IO.inspect(more[0])
  puts(Inv.count_at(more, 1))
  puts(Inv.count_at(more, 2))
end
