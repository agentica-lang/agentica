export struct Item
  name: String
  count: Int
end

export enum Level
  Empty
  Low(Int)
  Plenty
end

export def level(item: Item) -> Level
  if item.count == 0
    return Level.Empty
  elsif item.count < 5
    return Level.Low(item.count)
  end
  return Level.Plenty
end

export def pick(items: List[Item], index: Int) -> Item
  return items[index]
end
