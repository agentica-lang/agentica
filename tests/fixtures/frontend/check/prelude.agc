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
  letters = items.flat_map do |item| item.name.split("") end
  halves = numbers.partition do |n| n > 2 end
  head = numbers.take_while do |n| n < 5 end
  tail = numbers.drop_while do |n| n < 5 end
  pairs = numbers.each_slice(2)
  by_count = items.group_by do |item| item.count end
  by_name = items.group_by do |item| item.name end
  counts = words.tally
  distinct = numbers.uniq
  total = numbers.sum
  mass = items.map do |item| item.weight end.sum
  lightest = items.min_by do |item| item.weight end
  first_name = items.min_by do |item| item.name end
  most = items.max_by do |item| item.count end
  numbers_by = {"a": 1, "b": 2}
  numbers_by.each do |key, value|
    puts("#{key} #{value}")
  end
  big = numbers_by.filter do |key, value| value > 1 end
  puts(String.compare("a", "b"))
  puts(found)
end
