# A struct with a type parameter: Page[T] holds one page of any kind of item. The type argument comes from the field
# values, or from the expected type when a value is an empty list.
struct Page[T]
  items: List[T]
  number: Int = 1
end

def numbers_page() -> Page[Int] = Page(items: [10, 20, 30])

def names_page() -> Page[String] = Page(items: ["ana", "ben"], number: 2)

def last_page() -> Page[String] = Page(items: [], number: 3)

def describe(page: Page[String]) -> String = "page #{page.number}: #{page.items.size} item(s)"

def main() -> Void
  numbers = numbers_page()
  puts(numbers.items.map do |n| n * 2 end)
  names = names_page()
  puts(names.items[0].upcase)
  puts(describe(names))
  puts(describe(last_page()))
  puts(names.with(number: 9))
end
