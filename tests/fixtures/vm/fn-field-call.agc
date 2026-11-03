# store.put(a, b) calls the function in the Fn field put, as store.put.call(a, b) does.
struct Store[T]
  get: Fn[String, Result[T]]
  put: Fn[String, T, Result[Void]]
  note: Fn[String, Void]
end

struct Counter
  next: Fn[Int, Int]
  name: String
end

def lookup(key: String) -> Result[String]
  return ok("value of #{key}")
end

def save(key: String, value: String) -> Result[Void]
  if key == ""
    return error("empty key")
  end

  return ok()
end

def say(text: String) -> Void
  puts("note: #{text}")
end

def succ(n: Int) -> Int
  return n + 1
end

def copy(store: Store[String], from: String, to: String) -> Result[Void]
  value = try store.get(from)
  try store.put(to, value)
  store.note("copied #{from}")
  return ok()
end

def main() -> Void
  store = Store(get: &lookup, put: &save, note: &say)
  puts(store.get("a"))
  puts(store.put("", "x"))
  puts(copy(store, "a", "b"))
  puts(["a", "b"].map do |key| store.get(key).unwrap_or("") end)

  counter = Counter(next: &succ, name: "c")
  puts(counter.next(counter.next(1)))
  puts(counter.next(1) == counter.next.call(1))
  puts(counter.name.upcase)
  puts([counter].map do |c| c.next(10) end)
end
