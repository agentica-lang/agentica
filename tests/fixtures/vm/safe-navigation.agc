struct Address
  city: String
  zip: Optional[String]
end

struct User
  name: String
  address: Optional[Address]
  greet: Fn[String, String]
end

def noisy(text: String) -> String
  puts("computed #{text}")
  text
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
end
