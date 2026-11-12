struct Item
  name: String
  weight: Float
  count: Int
end

def show(label: String, value: String) -> Void
  puts("#{label}: #{value}")
end

def main() -> Void
  numbers = [3, 1, 4, 1, 5, 9, 2, 6]
  items = [
    Item(name: "pear", weight: 1.5, count: 2),
    Item(name: "apple", weight: 0.5, count: 2),
    Item(name: "fig", weight: 0.5, count: 7),
  ]
  empty: List[Int] = []

  show("find", numbers.find { |n| n > 4 }.to_s)
  show("find none", numbers.find { |n| n > 40 }.to_s)
  show("find empty", empty.find { |n| n > 0 }.to_s)
  _ = numbers.find do |n|
    puts("visit find #{n}")
    n > 3
  end
  numbers.take_while do |n|
    puts("visit take_while #{n}")
    n < 4
  end
  numbers.drop_while do |n|
    puts("visit drop_while #{n}")
    n < 4
  end
  numbers.take(3).partition do |n|
    puts("visit partition #{n}")
    n > 3
  end
  numbers.take(3).min_by do |n|
    puts("visit min_by #{n}")
    n
  end
  show("find struct", items.find { |item| item.count > 5 }.unwrap!.name)

  numbers.each_with_index do |n, index|
    puts("#{index}=#{n}")
  end
  empty.each_with_index do |_, index|
    puts("never #{index}")
  end

  show("flat_map", numbers.take(3).flat_map { |n| [n, n * 10] }.to_s)
  show("flat_map empty parts", numbers.take(3).flat_map { |n| List.repeat(n, n - 1) }.to_s)
  show("flat_map strings", items.flat_map { |item| item.name.split("") }.take(6).to_s)
  show("partition", numbers.partition { |n| n > 3 }.to_s)
  show("partition empty", empty.partition { |n| n > 3 }.to_s)
  show("take_while", numbers.take_while { |n| n < 5 }.to_s)
  show("take_while all", numbers.take_while { |n| n < 50 }.to_s)
  show("take_while none", numbers.take_while { |n| n > 50 }.to_s)
  show("drop_while", numbers.drop_while { |n| n < 5 }.to_s)
  show("drop_while all", numbers.drop_while { |n| n < 50 }.to_s)
  show("drop_while none", numbers.drop_while { |n| n > 50 }.to_s)
  show("each_slice 3", numbers.each_slice(3).to_s)
  show("each_slice 4", numbers.each_slice(4).to_s)
  show("each_slice 100", numbers.each_slice(100).to_s)
  show("each_slice empty", empty.each_slice(2).to_s)
  slices = numbers.each_slice(3)
  slices.each do |slice|
    puts(slice.sum)
  end

  show("group_by int", numbers.group_by { |n| n % 3 }.to_s)
  show("group_by string", items.group_by { |item| item.name.slice(0, 1) }.to_s)
  show("group_by struct", items.group_by { |item| item.count }.to_s)
  show("group_by empty", empty.group_by { |n| n }.to_s)
  show("tally ints", numbers.tally.to_s)
  show("tally strings", ["b", "a", "b", "c", "a", "b"].tally.to_s)
  show("tally empty", empty.tally.to_s)
  show("uniq ints", numbers.uniq.to_s)
  show("uniq strings", ["b", "a", "b", "c", "a"].uniq.to_s)
  show("uniq empty", empty.uniq.to_s)

  show("sum ints", numbers.sum.to_s)
  show("sum empty", empty.sum.to_s)
  show("sum floats", [0.5, 0.25, 2.0].sum.to_s)
  show("sum empty floats", List.repeat(1.0, 0).sum.to_s)
  show("sum mapped", items.map { |item| item.weight }.sum.to_s)

  show("min_by int", numbers.min_by { |n| n }.to_s)
  show("max_by int", numbers.max_by { |n| n }.to_s)
  show("min_by tie", items.min_by { |item| item.weight }.unwrap!.name)
  show("max_by tie", items.max_by { |item| item.count }.unwrap!.name)
  show("max_by tie first", ["bb", "aa", "c"].max_by { |word| word.length }.to_s)
  show("min_by string", items.min_by { |item| item.name }.unwrap!.name)
  show("max_by string", items.max_by { |item| item.name }.unwrap!.name)
  show("min_by empty", empty.min_by { |n| n }.to_s)
  show("max_by empty", empty.max_by { |n| n }.to_s)
  nan = Float.from_bits(9221120237041090560)
  keys = [nan, 3.0, 1.0, nan, 2.0]
  show("min_by nan", keys.min_by { |key| key }.unwrap!.to_s)
  show("max_by nan", keys.max_by { |key| key }.unwrap!.to_s)
  show("min_by first nan", [nan, 1.0].min_by { |key| key }.unwrap!.to_s)
  show("max_by only nan", [nan, nan].max_by { |key| key }.unwrap!.to_s)
  show("min_by nan struct", items.min_by { |_| nan }.unwrap!.name)

  table = {"a": 1, "b": 2, "c": 3}
  table.each do |key, value|
    puts("#{key}->#{value}")
  end
  show("filter", table.filter { |_, value| value != 2 }.to_s)
  show("filter none", table.filter { |_, value| value > 9 }.to_s)
  show("filter keys", table.filter { |key, _| key != "a" }.to_s)
  no_items: Map[String, Int] = {}
  show("filter empty", no_items.filter { |_, _| true }.to_s)
  no_items.each do |key, _|
    puts("never #{key}")
  end

  show("compare equal", String.compare("abc", "abc").to_s)
  show("compare less", String.compare("abc", "abd").to_s)
  show("compare prefix", String.compare("ab", "abc").to_s)
  show("compare greater", String.compare("b", "abc").to_s)
  show("compare unicode", String.compare("é", "z").to_s)
  show("compare method", "a".compare("b").to_s)
end
