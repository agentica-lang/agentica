import Stock from "stock"

export def restock(items: List[Stock.Item], extra: Int) -> List[Stock.Item]
  return items.map do |item| Stock.Item(name: item.name, count: item.count + extra) end
end

export def count_at(items: List[Stock.Item], index: Int) -> Int
  return Stock.pick(items, index).count
end
