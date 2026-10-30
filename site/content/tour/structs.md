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

Build a struct with every field, each by name, in any order. A missing field is an error:

```agentica {expect="CHECK-MISSING-FIELD"}
struct Point
  x: Int
  y: Int
end

def main() -> Void
  p = Point(x: 1)
end
```

## Default values

A field written `name: Type = value` has a default, and a constructor may leave it out. A field without a default must still be given.

```agentica
struct Options
  name: String
  retries: Int = 3
  tags: List[String] = []
end

def main() -> Void
  puts(Options(name: "a"))
  puts(Options(name: "b", retries: 1))
end
```

```output
Options(name: "a", retries: 3, tags: [])
Options(name: "b", retries: 1, tags: [])
```

A default follows the rules of a parameter default: a literal, `true`, `false`, `nil`, `none`, `[]`, `{}` or an enum variant without a payload. Anything else is `CHECK-DEFAULT-VALUE`, and a value of the wrong type is `CHECK-TYPE-MISMATCH`.

```agentica {expect="CHECK-DEFAULT-VALUE"}
struct Options
  retries: Int = 1 + 2
end

def main() -> Void
  puts(Options())
end
```

`with` and `JSON.decode` do not use defaults: `with` copies a value, and a decode still needs every key.

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

`with` needs at least one field. Each must be named (`PARSE-UNEXPECTED-TOKEN` otherwise), appear once, exist in the struct and have the right type (`CHECK-TYPE-MISMATCH`):

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

## List the fields

`Type.members` is a `List[StructMember]` with one entry per field of a struct type, in declaration order. A `StructMember` has two `String` fields: `name` and `type`, the field type written as source. A tool such as a table mapper can build SQL from a struct with it.

```agentica
type Id = Int

struct Address
  city: String
end

struct User
  id: Id
  name: String
  tags: List[String]
  home: Address
end

def main() -> Void
  User.members.each do |m|
    puts("#{m.name}: #{m.type}")
  end
end
```

```output
id: Int
name: String
tags: List[String]
home: Address
```

The type is the one the checker prints, so an alias is expanded (`Id` gives `Int`). `members` is on the type and not on a value: `user.members` reads a field of that name, and a struct may have one. An enum, a resource or an alias is not a struct, so `Color.members` is `CHECK-UNKNOWN-METHOD` and `Id.members` is `CHECK-UNKNOWN-TYPE`.

```agentica {expect="CHECK-UNKNOWN-METHOD"}
enum Color
  Red
end

def main() -> Void
  puts(Color.members.size)
end
```

## Type parameters

A struct can take type parameters after its name, as an enum does. The type argument comes from the values you give:

```agentica
struct Box[T]
  value: T
end

struct Pair[A, B]
  first: A
  second: B
end

def main() -> Void
  count = Box(value: 41)
  puts(count.value + 1)
  pair = Pair(first: "one", second: count)
  puts(pair.second.value)
  puts(pair)
  puts(count.with(value: 7))
end
```

```output
42
41
Pair(first: "one", second: Box(value: 41))
Box(value: 7)
```

`count` is a `Box[Int]`, so `count.value` is an `Int`. A type names all its arguments: `Box[Int]`, `Pair[String, Box[Int]]`. A bare `Box` or the wrong number of arguments is `CHECK-UNKNOWN-TYPE`.

```agentica
struct Box[T]
  value: T
end

def total(box: Box[List[Int]]) -> Int
  return box.value.sum
end

def main() -> Void
  puts(total(Box(value: [1, 2, 3])))
  puts(total(Box(value: [])))
end
```

```output
6
0
```

An empty list or map cannot say what the argument is, so it needs a type from the place where the struct is used: a parameter, as above, a return type, a field or a variable with a type. Without one it is `CHECK-ENUM-TYPE-INFERENCE`.

```agentica {expect="CHECK-ENUM-TYPE-INFERENCE"}
struct Box[T]
  value: T
end

def main() -> Void
  box = Box(value: [])
end
```

Values that disagree are `CHECK-TYPE-MISMATCH`. A parameter cannot be a `Map` key (`CHECK-MAP-KEY-TYPE`), and a field named `with` cannot have a parameter as its type (`CHECK-REDEFINED-NAME`), since the argument could be a function. `JSON.encode` writes a generic instance, but `JSON.decode` and `JSON.schema` refuse one (`CHECK-NOT-DECODABLE`). An imported struct is written `Models.Box[Int]`.

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
