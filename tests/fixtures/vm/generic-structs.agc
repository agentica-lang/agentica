import Lib from "lib/generic_structs_lib"
import {Stack} from "lib/generic_structs_lib"

struct Box[T]
  value: T
end

struct Pair[A, B]
  first: A
  second: B
end

struct Tree[T]
  value: T
  children: List[Tree[T]]
end

# The adapter of the design: one shape, filled once for each backend.
struct Storage[T]
  get: Fn[String, Result[T]]
  put: Fn[String, T, Result[Void]]
end

def size_of(box: Box[List[Int]]) -> Int
  return box.value.size
end

def empty_box() -> Box[List[String]]
  return Box(value: [])
end

def first_length(storage: Storage[String], key: String) -> Int
  return storage.get.call(key).unwrap_or("").length
end

def lookup(key: String) -> Result[String]
  return ok("value of #{key}")
end

def store(key: String, value: String) -> Result[Void]
  return ok()
end

def count(tree: Tree[Int]) -> Int
  total = tree.value
  for child in tree.children
    total += count(child)
  end

  return total
end

def main() -> Void
  # The type argument comes from the field value, then from the expected type.
  ints = Box(value: 41)
  words = Box(value: "agentica")
  puts(ints.value + 1)
  puts(words.value.upcase)
  puts(size_of(Box(value: [])))
  puts(empty_box().value.size)

  pair = Pair(first: 1, second: "one")
  puts(pair.second.upcase)
  puts(pair)
  puts(pair.inspect)
  puts(Box(value: Box(value: 2.5)).value.value * 2.0)

  # with keeps the type arguments.
  moved = ints.with(value: 7)
  puts(moved.value)
  puts(ints.value)

  puts(Box.members)
  puts(JSON.encode(pair))
  puts(JSON.encode(Box(value: [1, 2])))

  tree = Tree(value: 1, children: [Tree(value: 2, children: []), Tree(value: 3, children: [])])
  puts(count(tree))

  storage = Storage(get: &lookup, put: &store)
  puts(first_length(storage, "k"))
  puts(storage.put.call("k", "v").ok?)

  stack: Stack[String] = Stack(label: "names")
  puts(stack)
  puts(Lib.push(Lib.single(1), 2))
  puts(Stack(items: [true]).items.size)
end
