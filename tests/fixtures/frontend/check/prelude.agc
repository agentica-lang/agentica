struct Item
  name: String
  weight: Float
  count: Int
end

def main() -> Void
  items = [Item(name: "b", weight: 1.5, count: 2), Item(name: "a", weight: 0.5, count: 2)]
  numbers = [3, 1, 4, 1, 5]
  words = ["x", "y", "x"]
  found = items.find do |item| item.count > 1 end
  items.each_with_index do |item, index|
    puts("#{index} #{item.name}")
  end
  _letters = items.flat_map do |item| item.name.split("") end
  _halves = numbers.partition do |n| n > 2 end
  _head = numbers.take_while do |n| n < 5 end
  _tail = numbers.drop_while do |n| n < 5 end
  _pairs = numbers.each_slice(2)
  _by_count = items.group_by do |item| item.count end
  _by_name = items.group_by do |item| item.name end
  _counts = words.tally
  _distinct = numbers.uniq
  _total = numbers.sum
  _mass = items.map { |item| item.weight }.sum
  _ = items.min_by do |item| item.weight end
  _ = items.min_by do |item| item.name end
  _ = items.max_by do |item| item.count end
  numbers_by = {"a": 1, "b": 2}
  numbers_by.each do |key, value|
    puts("#{key} #{value}")
  end
  _big = numbers_by.filter do |_, value| value > 1 end
  puts(String.compare("a", "b"))
  puts(found)
end
