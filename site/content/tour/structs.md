---
title: Structs
weight: 10
description: Declare records with typed fields, build them, read their fields and copy them with some fields changed.
---

## Declare a struct

A struct is a record with named, typed fields. Declare it at the top of the
file.

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

Fields cannot be assigned. `value.with(...)` is a copy of the struct with some fields changed, and the original stays as it was. Name each field you change, with a value of the field's type:

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

Change several fields at once, in any order. Every value is computed from the struct as it was before the update, so two fields can swap:

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

To change a field of a struct inside a struct, update both levels. Updates also chain:

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

A function that loops by calling itself can carry its state in a struct and change only what moves:

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

`with` needs at least one field, each by name and only once, and a field the struct has:

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

`with` is not a reserved word. It only means the update after a `.` and before `(`, so a struct can still have a field named `with` (a function-typed field of that name is `CHECK-REDEFINED-NAME`).

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

Structs have fields only. A field can be named `to_s`: `b.to_s` then reads the field, not the text form of `b`. Write functions that take the struct:

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
