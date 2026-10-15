enum Option[T]
  Some(T)
  None
end

enum Tree
  Leaf
  Node(Tree, Int, Tree)
end

def depth(t: Tree) -> Int
  case t
    Tree.Leaf -> return 0
    Tree.Node(l, _, r) ->
      a = depth(l)
      b = depth(r)
      if a > b
        return a + 1
      end
      return b + 1
  end
end

def first(xs: List[Int]) -> Option[Int]
  if xs.size == 0
    return Option.None
  end
  return Option.Some(xs[0])
end

def main() -> Void
  t = Tree.Node(Tree.Node(Tree.Leaf, 1, Tree.Leaf), 2, Tree.Leaf)
  puts(depth(t))
  case first([4])
    Option.Some(n) -> puts(n)
    Option.None -> puts("none")
  end
  level = LogLevel.Warning
  puts(level.to_s)
end
