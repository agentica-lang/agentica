# Optional[T]: some and none in fields, lists, maps, generics and constants; case, ==, the methods and the text forms.
DEFAULT_AGE = some(18)
NO_AGE: Optional[Int] = none

struct User
  name: String
  age: Optional[Int]
end

struct Box[T]
  item: Optional[T]
end

def describe(age: Optional[Int]) -> String
  case age
    some(n) if n >= 18 -> return "adult #{n}"
    some(n) -> return "minor #{n}"
    none -> return "unknown"
  end
end

def first[T](items: List[T]) -> Optional[T]
  if items.size == 0
    return none
  end
  return some(items[0])
end

def half(numbers: List[Int]) -> Result[Int]
  n = try first(numbers).to_result("no number")
  return ok(n / 2)
end

def main() -> Void
  users = [User(name: "ana", age: some(31)), User(name: "bo", age: none), User(name: "cy", age: some(7))]
  for user in users
    puts("#{user.name}: #{describe(user.age)} #{user.age}")
  end
  puts(users.map do |user| user.age.unwrap_or(0) end)
  puts(users.map do |user| user.age.map do |n| n + 1 end end)
  puts(users.map do |user| [user.age.some?, user.age.none?] end)
  puts(users[0].age.unwrap!)
  puts(DEFAULT_AGE.inspect + " " + NO_AGE.inspect)
  words: List[String] = []
  puts([first(words), first(["x", "y"])])
  puts(first(words).map do |w| w.length end)
  puts(half([9, 4]).to_s + " " + half([]).to_s)
  ages: Map[String, Optional[Int]] = {"ana": some(31), "bo": none}
  puts(ages)
  puts(ages["bo"].to_result("bo has no age"))
  box = Box(item: some("hi"))
  empty: Box[Int] = Box(item: none)
  puts([box.item.inspect, empty.item.inspect])
  nested: List[Optional[Optional[Int]]] = [some(some(1)), some(none), none]
  for value in nested
    case value
      some(some(n)) -> puts("some some #{n}")
      some(none) -> puts("some none")
      _ -> puts("none")
    end
  end
  puts([some(1) == some(1), some(1) == some(2), users[1].age == none, users[1].age != none, NO_AGE == none])
  puts([nested[1] == some(none), nested[0] == some(some(1)), some("a".bytes) == some("a".bytes)])
end
