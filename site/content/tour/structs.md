---
title: Structs
weight: 10
description: Declare records with typed fields, build them and read their fields.
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

Fields cannot be assigned. Build a new struct with the new value:

```agentica
struct Account
  owner: String
  balance: Int
end

def deposit(account: Account, amount: Int) -> Account
  return Account(owner: account.owner, balance: account.balance + amount)
end

def main() -> Void
  account = Account(owner: "Bob", balance: 10)
  account = deposit(account, 5)
  puts(account.balance)
end
```

```output
15
```

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
