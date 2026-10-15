struct Address
  city: String
  zip: Int
end

struct User
  name: String
  age: Int
  address: Address
  tags: List[String]
  scores: Map[String, Int]
  with: Int
end

struct Counter
  pos: Int
  total: Int
  seen: Int
  mode: String
  depth: Int
  flag: Bool
end

def user() -> User
  return User(name: "Ana", age: 30, address: Address(city: "Cusco", zip: 1), tags: [], scores: {}, with: 0)
end

def trace(label: String, n: Int) -> Int
  puts("eval #{label}")
  return n
end

def traced_user() -> User
  puts("eval receiver")
  return user()
end

def step(c: Counter) -> Counter
  if c.pos >= 30000
    return c
  end
  return step(c.with(pos: c.pos + 1, total: c.total + c.pos, seen: c.seen + 1))
end

def main() -> Void
  ana = user()

  # The receiver is unchanged; the update is a new value.
  older = ana.with(age: 31)
  puts(ana.age)
  puts(older.age)
  puts(older)

  # Nested updates and several fields in any order.
  moved = ana.with(address: ana.address.with(city: "Lima"), tags: ["a", "b"])
  puts(moved)
  puts(ana.address.city)
  scrambled = ana.with(scores: {"x": 1}, age: 1, name: "Zed")
  puts(scrambled)

  # [] and {} take the field type; a field named with is data, and with(...) updates it.
  cleared = scrambled.with(scores: {}, tags: [])
  puts(cleared.scores.size)
  puts(ana.with(with: 5).with)

  # The receiver runs first, then the values from left to right, then the copy is made.
  mixed = traced_user().with(age: trace("age", 40), name: "Bea" + "x", tags: [trace("tag", 1).to_s])
  puts(mixed)

  # The values run in the order they are written, not in the order of the struct's fields (age, scores, with).
  reversed_order = traced_user().with(with: trace("with", 3), scores: {"k": trace("scores", 2)}, age: trace("age", 1))
  puts(reversed_order)

  # Values read the receiver as it was before the update.
  swapped = ana.with(age: ana.address.zip, address: Address(city: "Quito", zip: ana.age))
  puts(swapped.age)
  puts(swapped.address.zip)

  # Chains and updates of results of calls.
  chained = user().with(age: 1).with(age: 2).with(name: "Cy")
  puts(chained)

  # A block captures the struct and updates it per element.
  ages = [1, 2, 3].map do |n| ana.with(age: n).age end
  puts(ages)
  people = [ana, older].map do |p| p.with(age: p.age + 10) end
  puts(people.map do |p| p.age end)

  # A tail-recursive step function with .with runs in constant stack.
  done = step(Counter(pos: 0, total: 0, seen: 0, mode: "go", depth: 0, flag: true))
  puts(done.pos)
  puts(done.total)
  puts(done.seen)
  puts(done.mode)

  # The assigned local is replaced by a new value; copies made earlier keep theirs.
  held = ana
  ana = ana.with(name: "Dan")
  puts(held.name)
  puts(ana.name)
end
