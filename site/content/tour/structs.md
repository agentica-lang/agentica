---
title: Structs
weight: 10
description: Declare records with typed fields, build them, read their fields and copy them with some fields changed.
---

## Declare a struct

A struct is a record with named, typed fields. Declare it at the top of the file.

```agentica
struct User
  name: String
  age: Int
end

def main() -> Void
  user = User(name: "Ana", age: 25)
  puts(user.name)
  puts(user)
end
```

```output
Ana
User(name: "Ana", age: 25)
```

Build a struct with every field, each by name, in any order:

```agentica
struct Point
  x: Int
  y: Int
end

def main() -> Void
  p = Point(y: 2, x: 1)
  puts("#{p.x}, #{p.y}")
end
```

```output
1, 2
```

A missing field is an error:

```agentica {expect="CHECK-MISSING-FIELD"}
struct Point
  x: Int
  y: Int
end

def main() -> Void
  p = Point(x: 1)
end
```

## Change a field

Fields cannot be assigned. `value.with(...)` copies the struct with the named fields changed. The original stays as it was.

```agentica
struct Account
  owner: String
  balance: Int
end

def deposit(account: Account, amount: Int) -> Account
  return account.with(balance: account.balance + amount)
end

def main() -> Void
  account = Account(owner: "Bob", balance: 10)
  richer = deposit(account, 5)
  puts(richer)
  puts(account)
end
```

```output
Account(owner: "Bob", balance: 15)
Account(owner: "Bob", balance: 10)
```

Every value is computed from the struct before the update, so fields can swap:

```agentica
struct Pair
  left: Int
  right: Int
  label: String
end

def main() -> Void
  pair = Pair(left: 1, right: 2, label: "p")
  swapped = pair.with(left: pair.right, right: pair.left)
  puts(swapped)
  puts(pair.with(label: "q", left: 0))
end
```

```output
Pair(left: 2, right: 1, label: "p")
Pair(left: 0, right: 2, label: "q")
```

For a field inside a struct, update both levels. Updates chain:

```agentica
struct Address
  city: String
  zip: Int
end

struct User
  name: String
  address: Address
end

def main() -> Void
  ana = User(name: "Ana", address: Address(city: "Cusco", zip: 8))
  moved = ana.with(address: ana.address.with(city: "Lima"))
  puts(moved)
  puts(moved.with(name: "Bea").with(address: Address(city: "Quito", zip: 1)))
end
```

```output
User(name: "Ana", address: Address(city: "Lima", zip: 8))
User(name: "Bea", address: Address(city: "Quito", zip: 1))
```

A recursive function can carry its state in a struct:

```agentica
struct Scan
  pos: Int
  total: Int
  limit: Int
end

def run(s: Scan) -> Scan
  if s.pos >= s.limit
    return s
  end
  return run(s.with(pos: s.pos + 1, total: s.total + s.pos))
end

def main() -> Void
  done = run(Scan(pos: 0, total: 0, limit: 100000))
  puts(done.total)
end
```

```output
4999950000
```

`with` needs at least one field. Each must be named, appear once and exist in the struct:

```agentica {expect="PARSE-UNEXPECTED-TOKEN"}
struct Point
  x: Int
  y: Int
end

def main() -> Void
  p = Point(x: 1, y: 2)
  q = p.with(5)
end
```

```agentica {expect="CHECK-UNKNOWN-FIELD"}
struct Point
  x: Int
  y: Int
end

def main() -> Void
  p = Point(x: 1, y: 2)
  q = p.with(z: 5)
end
```

```agentica {expect="CHECK-TYPE-MISMATCH"}
struct Point
  x: Int
  y: Int
end

def main() -> Void
  p = Point(x: 1, y: 2)
  q = p.with(x: "one")
end
```

A bare `p.with(x: 2)` changes nothing, so it is `CHECK-UNUSED-VALUE`. Assign the result: `p = p.with(x: 2)`.

```agentica {expect="CHECK-UNUSED-VALUE"}
struct Point
  x: Int
  y: Int
end

def main() -> Void
  p = Point(x: 1, y: 2)
  p.with(x: 2)
end
```

`with` is not reserved: a struct can have a field named `with`, unless that field is a function (`CHECK-REDEFINED-NAME`).

## Structs in structs and lists

Fields can be lists, maps, other structs and enums.

```agentica
struct Item
  name: String
  price: Int
end

struct Order
  id: Int
  items: List[Item]
end

def main() -> Void
  order = Order(id: 7, items: [Item(name: "tea", price: 3), Item(name: "cake", price: 5)])
  total = order.items.reduce(0) do |sum, item| sum + item.price end
  puts("order #{order.id}: #{total}")
end
```

```output
order 7: 8
```

## No methods

Structs have fields only. A field named `to_s` shadows the text form, so write functions that take the struct:

```agentica
struct Rect
  width: Int
  height: Int
end

def area(r: Rect) -> Int
  return r.width * r.height
end

def main() -> Void
  puts(area(Rect(width: 3, height: 4)))
end
```

```output
12
```

Structs cannot be compared with `==`. Compare their fields instead.
