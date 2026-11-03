# == and != on structs, lists, maps, sets, Results, Optionals and enums: field by field, in order, at any depth;
# maps and sets in any order; a NaN anywhere is not equal, not even to itself.
struct User
  name: String
  age: Int
  tags: List[String]
end

struct Box[T]
  item: T
end

struct Node
  label: String
  children: List[Node]
end

enum Shape
  Circle(Float)
  Rect(Float, Float)
  Dot
end

enum Maybe[T]
  Just(T)
  Nothing
end

enum Tree
  Leaf(Int)
  Branch(List[Tree])
end

def same_user?(a: User, b: User) -> Bool
  return a == b
end

def main() -> Void
  ana = User(name: "Ana", age: 30, tags: ["admin"])
  copy = User(name: "Ana", age: 30, tags: ["admin"])
  puts("struct #{ana == copy} #{ana != copy} #{ana.with(age: 31) != copy} #{same_user?(ana, ana.with(tags: []))}")
  puts("list #{[1, 2, 3] == [1, 2, 3]} #{[1, 2] == [2, 1]} #{[1, 2] == [1, 2, 3]} #{[[1], []] == [[1], []]}")
  users = [ana, copy.with(name: "Bo")]
  puts("list of structs #{users == [copy, ana.with(name: "Bo")]} #{users == [copy, copy]}")
  puts("enum #{Shape.Circle(1.0) == Shape.Circle(1.0)} #{Shape.Circle(1.0) == Shape.Rect(1.0, 1.0)}")
  puts("unit variant #{Shape.Dot == Shape.Dot} #{Shape.Dot != Shape.Circle(0.0)}")
  just: Maybe[List[Int]] = Maybe.Just([1])
  puts("generic enum #{just == Maybe.Just([1])} #{just == Maybe.Nothing}")
  puts("generic struct #{Box(item: [1, 2]) == Box(item: [1, 2])} #{Box(item: "a") != Box(item: "b")}")
  ages = {"ana": 30, "bo": 25}
  puts("map #{ages == {"bo": 25, "ana": 30}} #{ages == {"ana": 30}} #{ages == {"ana": 30, "bo": 26}}")
  puts("set #{Set.new([1, 2]) == Set.new([2, 1])} #{Set.new(["a"]) == Set.new(["b"])}")
  found: Result[Int] = ok(1)
  failed: Result[Int] = error("missing")
  done: Result[Void] = ok()
  puts("result #{found == ok(1)} #{found == ok(2)} #{failed == error("missing")} #{failed != found} #{done == ok()}")
  puts("optional #{some(ana) == some(copy)} #{some(ana) == none}")
  tree = Node(label: "root", children: [Node(label: "leaf", children: [])])
  same_tree = Node(label: "root", children: [Node(label: "leaf", children: [])])
  puts("recursive #{tree == same_tree} #{tree == same_tree.with(children: [])}")
  puts("enum tree #{Tree.Branch([Tree.Leaf(1)]) == Tree.Branch([Tree.Leaf(1)])} #{Tree.Leaf(1) == Tree.Branch([])}")
  nan = Float.from_bits(9221120237041090560)
  circle = Shape.Circle(nan)
  floats = [nan]
  puts("nan #{circle == circle} #{floats == floats} #{Box(item: nan) != Box(item: nan)} #{[0.0] == [-0.0]}")
  puts("bytes #{["x".bytes] == ["x".bytes]} #{Box(item: "x".bytes) == Box(item: "y".bytes)}")
end
