struct User
  name: String
  age: Int
  tags: List[String]
  scores: Map[String, Int]
  with: Int
end

def make() -> User
  return User(name: "Ana", age: 30, tags: [], scores: {}, with: 0)
end

def main() -> Void
  ana = make()
  older: User = ana.with(age: ana.age + 1)
  cleared = ana.with(tags: [], scores: {})
  deep = make().with(name: "Bea", age: 2).with(tags: ["a"])
  w: Int = ana.with
  same_name = ana.with(with: 5)
  puts("#{older.age} #{cleared.tags.size} #{deep.name} #{w}")
end

