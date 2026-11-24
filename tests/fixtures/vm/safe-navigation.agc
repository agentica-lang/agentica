struct Address
  city: String
  zip: Optional[String]
end

struct User
  name: String
  address: Optional[Address]
  greet: Fn[String, String]
end

struct Logger
  log: Fn[String, Void]
end

def noisy(text: String) -> String
  puts("computed #{text}")
  text
end

def maybe(text: String) -> Optional[String]
  puts("looked #{text}")
  some(text)
end

def main() -> Void
  hello = ->(who: String) { "hello #{who}" }
  lima = Address(city: "Lima", zip: some("15001"))
  ana = User(name: "Ana", address: some(lima), greet: hello)
  ben = User(name: "Ben", address: none, greet: hello)

  puts(ana.address&.city)
  puts(ben.address&.city)
  puts(ana.address&.city.unwrap_or("?"))
  puts(ben.address&.city.unwrap_or("?"))

  puts(ana.address&.zip)
  puts(ana.address&.zip&.size)
  puts(ben.address&.zip&.size)

  puts(some("abc")&.start_with?(noisy("a")))
  none_text: Optional[String] = none
  puts(none_text&.start_with?(noisy("a")))

  puts(some([1, 2, 3])&.map do |n| n * 2 end)
  none_list: Optional[List[Int]] = none
  puts(none_list&.map do |n| n * 2 end)

  puts(some(ana)&.greet("you"))
  puts(some(ben)&.address&.city)

  # A member that gives nothing runs for some and does nothing for none; the target runs once.
  logger: Optional[Logger] = some(Logger(log: ->(line: String) { puts("log #{line}") }))
  silent: Optional[Logger] = none
  logger&.log("one")
  silent&.log(noisy("never"))
  some([1, 2])&.each do |n| puts("each #{n}") end
  puts(maybe("target")&.size)

  # A method that gives an Optional is flat.
  table: Optional[Map[String, Int]] = some({"a": 1})
  puts(table&.get("a"))
  puts(table&.get("z"))
  none_table: Optional[Map[String, Int]] = none
  puts(none_table&.get("a"))

  # Inside a lambda, and inside the block of another &.
  size = ->(text: Optional[String]) { text&.size }
  puts(size.call(some("four")))
  puts(size.call(none))
  puts(some(["ab", "c"])&.map do |text| some(text)&.size.unwrap_or(0) end)
end
