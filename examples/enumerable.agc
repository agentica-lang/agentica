struct Order
  customer: String
  items: Int
  total: Float
end

# The List and Map methods written in the compiler prelude: find, partition, group_by, tally, uniq, sum, min_by, max_by,
# each_slice, take_while, drop_while, flat_map, each_with_index. Each has one name and runs its block once for each
# element, from the first to the last.
def main() -> Void
  orders = [
    Order(customer: "ana", items: 3, total: 30.0),
    Order(customer: "bob", items: 1, total: 12.5),
    Order(customer: "ana", items: 2, total: 8.0),
    Order(customer: "eve", items: 5, total: 12.5),
  ]

  # find, min_by and max_by give a Result: an empty list has no answer.
  big = orders.find do |order| order.items > 4 end
  puts("big order: #{big.unwrap!.customer}")
  puts(orders.find do |order| order.items > 9 end.message)
  cheapest = orders.min_by do |order| order.total end
  puts("cheapest: #{cheapest.unwrap!.customer}")
  puts("most items: #{orders.max_by do |order| order.items end.unwrap!.customer}")

  # Ties go to the first element: bob and eve both have 12.5.
  puts("tie: #{orders.drop(1).max_by do |order| order.total end.unwrap!.customer}")

  # Groups and counts keep the order of first appearance.
  by_customer = orders.group_by do |order| order.customer end
  by_customer.each do |customer, list|
    puts("#{customer}: #{list.map do |order| order.items end.sum} items")
  end
  puts(orders.map do |order| order.customer end.tally)
  puts(orders.map do |order| order.customer end.uniq)
  puts("revenue: #{orders.map do |order| order.total end.sum}")

  # partition gives [accepted, rejected].
  halves = orders.partition do |order| order.total > 10.0 end
  puts("#{halves[0].size} large, #{halves[1].size} small")

  # Slices, prefixes and callbacks with an index.
  puts((1..7).to_a.each_slice(3))
  puts((1..7).to_a.take_while do |n| n < 4 end)
  puts((1..7).to_a.drop_while do |n| n < 4 end)
  puts(["a", "b"].flat_map do |word| [word, word.upcase] end)
  ["x", "y"].each_with_index do |word, index|
    puts("#{index}: #{word}")
  end

  # Strings compare in the order of sort.
  puts("apple".compare("banana"))
  puts(by_customer.filter do |customer, list| list.size > 1 end.keys)
end
