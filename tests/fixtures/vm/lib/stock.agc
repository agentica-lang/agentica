struct Item
  name: String
  count: Int
end

enum Level
  Empty
  Low(Int)
  Plenty
end

def level(item: Item) -> Level
  if item.count == 0
    return Level.Empty
  elsif item.count < 5
    return Level.Low(item.count)
  end
  return Level.Plenty
end

def pick(items: List[Item], index: Int) -> Item
  return items[index]
end
