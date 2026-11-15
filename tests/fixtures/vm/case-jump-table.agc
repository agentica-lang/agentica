# A case with three or more variant arms jumps by the variant through a table (jump-variant): many arms, payloads,
# nested patterns and guards that fail over to a later arm of the same variant, or-patterns, an `_` arm that takes the
# variants no arm names, Optional, a generic enum, case values and nested cases. main runs them in a loop, so the JIT
# compiles the same code.
enum Op
  Push(Int)
  Pop
  Add
  Sub
  Mul
  Neg
  Dup
  Swap
  Jump(Int)
  Halt
end

enum Tree
  Leaf(Int)
  Pair(Tree, Tree)
  Tag(String, Tree)
  Empty
end

enum Box[T]
  One(T)
  Two(T, T)
  Three(T, T, T)
  Nothing
end

def name(op: Op) -> String
  case op
    Op.Push(n) -> "push #{n}"
    Op.Pop -> "pop"
    Op.Add -> "add"
    Op.Sub -> "sub"
    Op.Mul -> "mul"
    Op.Neg -> "neg"
    Op.Dup -> "dup"
    Op.Swap -> "swap"
    Op.Jump(to) -> "jump #{to}"
    Op.Halt -> "halt"
  end
end

def weight(op: Op) -> Int
  case op
    Op.Push(0) -> 100
    Op.Push(n) if n < 0 -> 200
    Op.Jump(n) if n > 10 -> 300
    Op.Push(n) -> n
    Op.Add, Op.Sub -> 1
    Op.Mul -> 2
    Op.Jump(_) -> 3
    _ -> 4
  end
end

# The variants no arm names go to the `_` arm; Push(2) fails its nested pattern and goes there too.
def fallback(op: Op) -> String
  result = ""
  case op
    Op.Pop -> result = "pop"
    Op.Add -> result = "add"
    Op.Push(1) -> result = "one"
    Op.Dup -> result = "dup"
    _ -> result = "other"
  end
  result
end

# An or-pattern first: a variant it does not take falls to the next arms, which keep their tag test.
def or_first(op: Op) -> String
  case op
    Op.Neg, Op.Dup, Op.Swap -> "stack"
    Op.Push(_) -> "push"
    Op.Pop -> "pop"
    Op.Halt -> "halt"
    Op.Jump(_) -> "jump"
    _ -> "math"
  end
end

def sum(tree: Tree) -> Int
  case tree
    Tree.Leaf(n) -> n
    Tree.Pair(Tree.Leaf(a), Tree.Leaf(b)) -> a * b
    Tree.Pair(left, right) -> sum(left) + sum(right)
    Tree.Tag("skip", _) -> 0
    Tree.Tag(label, inner) ->
      case inner
        Tree.Empty -> label.length
        Tree.Leaf(n) if n > 5 -> n + label.length
        Tree.Leaf(n) -> n
        Tree.Pair(_, _) -> sum(inner) * 2
        Tree.Tag(_, deeper) -> sum(deeper) + 1
      end
    Tree.Empty -> 0
  end
end

def pick(value: Optional[Int]) -> String
  case value
    some(1) -> "one"
    some(n) if n > 100 -> "big #{n}"
    some(n) -> "some #{n}"
    none -> "none"
  end
end

def total(box: Box[Int]) -> Int
  case box
    Box.One(a) -> a
    Box.Two(a, b) -> a + b
    Box.Three(a, b, c) -> a + b + c
    Box.Nothing -> -1
  end
end

def main() -> Void
  ops = [
    Op.Push(7),
    Op.Pop,
    Op.Add,
    Op.Sub,
    Op.Mul,
    Op.Neg,
    Op.Dup,
    Op.Swap,
    Op.Jump(3),
    Op.Jump(30),
    Op.Halt,
    Op.Push(0),
    Op.Push(-4),
    Op.Push(1),
  ]

  for op in ops
    puts("#{name(op)}: #{weight(op)} #{fallback(op)} #{or_first(op)}")
  end

  trees = [
    Tree.Leaf(4),
    Tree.Pair(Tree.Leaf(3), Tree.Leaf(5)),
    Tree.Pair(Tree.Leaf(1), Tree.Empty),
    Tree.Tag("skip", Tree.Leaf(9)),
    Tree.Tag("ab", Tree.Empty),
    Tree.Tag("ab", Tree.Leaf(9)),
    Tree.Tag("ab", Tree.Leaf(2)),
    Tree.Tag("ab", Tree.Pair(Tree.Leaf(2), Tree.Leaf(3))),
    Tree.Tag("ab", Tree.Tag("cd", Tree.Leaf(6))),
    Tree.Empty,
  ]

  sums = trees.map { |tree| sum(tree).to_s }
  puts(sums.join(" "))
  picks = [some(1), some(500), some(7), none].map { |value| pick(value) }
  puts(picks.join(", "))
  totals = [Box.One(1), Box.Two(2, 3), Box.Three(4, 5, 6), Box.Nothing].map { |box| total(box).to_s }
  puts(totals.join(" "))

  checksum = 0
  round = 0
  while round < 20000
    for op in ops
      checksum = (checksum * 31 + weight(op) + name(op).length + fallback(op).length + or_first(op).length) % 1000003
    end

    for tree in trees
      checksum = (checksum + sum(tree)) % 1000003
    end

    checksum = (checksum + pick(some(round)).length + total(Box.Two(round, 1))) % 1000003
    round += 1
  end
  puts("checksum #{checksum}")
end
