enum Option
  Some(Int)
  None
end

enum Shape
  Dot
  Circle(Int)
  Pair(Int, Int)
  Boxed(Option)
  Tagged(String, Option)
end

enum Tree
  Leaf(Int)
  Node(Tree, Tree)
end

def describe(shape: Shape) -> String
  case shape
    Shape.Circle(0) -> return "empty circle"
    Shape.Circle(r) if r > 100 -> return "big circle #{r}"
    Shape.Circle(r) -> return "circle #{r}"
    Shape.Pair(1, y) -> return "one then #{y}"
    Shape.Pair(x, y) if x == y -> return "twin #{x}"
    Shape.Pair(x, 3) -> return "#{x} then three"
    Shape.Pair(_, _) -> return "pair"
    Shape.Boxed(Option.Some(9)) -> return "boxed nine"
    Shape.Boxed(Option.Some(n)) if n < 0 -> return "boxed negative #{n}"
    Shape.Boxed(Option.Some(n)) -> return "boxed #{n}"
    Shape.Boxed(Option.None) -> return "boxed none"
    Shape.Boxed(_) -> return "boxed other"
    Shape.Tagged("a", Option.Some(n)) -> return "tagged a #{n}"
    Shape.Tagged(name, Option.None) -> return "tagged #{name} none"
    Shape.Tagged(name, _) -> return "tagged #{name}"
    Shape.Dot -> return "dot"
  end
end

# Nested patterns to three levels. A case is exhaustive by its unguarded arms with names and _ only: `Tree.Node(_, _)`
# covers Node, so the arms with a literal or a nested variant above it only pick special cases.
def twin(tree: Tree) -> String
  case tree
    Tree.Node(Tree.Leaf(a), Tree.Leaf(b)) if a == b -> return "twin leaves #{a}"
    Tree.Node(Tree.Leaf(a), Tree.Leaf(b)) -> return "leaves #{a} #{b}"
    Tree.Node(Tree.Node(Tree.Leaf(a), _), _) -> return "deep left #{a}"
    Tree.Node(_, _) -> return "node"
    Tree.Leaf(n) -> return "leaf #{n}"
  end
end

def classify(r: Result[Option]) -> String
  case r
    ok(Option.Some(0)) -> return "ok zero"
    ok(Option.Some(n)) if n < 0 -> return "ok negative"
    ok(Option.Some(n)) -> return "ok #{n}"
    ok(Option.None) -> return "ok none"
    ok(_) -> return "ok other"
    error("boom") -> return "boom"
    error(m) -> return "error #{m}"
  end
end

def sign(n: Int) -> String
  case n
    0 -> return "zero"
    _ if n < 0 -> return "negative"
    _ if n < 10 -> return "small"
    _ -> return "large"
  end
end

def main() -> Void
  shapes = [
    Shape.Circle(0), Shape.Circle(500), Shape.Circle(5), Shape.Pair(1, 9), Shape.Pair(4, 4), Shape.Pair(7, 3),
    Shape.Pair(7, 8), Shape.Boxed(Option.Some(9)), Shape.Boxed(Option.Some(-2)), Shape.Boxed(Option.Some(2)),
    Shape.Boxed(Option.None), Shape.Tagged("a", Option.Some(1)), Shape.Tagged("b", Option.None),
    Shape.Tagged("b", Option.Some(3)), Shape.Dot,
  ]
  for shape in shapes
    puts(describe(shape))
  end
  trees = [
    Tree.Node(Tree.Leaf(1), Tree.Leaf(1)), Tree.Node(Tree.Leaf(1), Tree.Leaf(2)),
    Tree.Node(Tree.Node(Tree.Leaf(5), Tree.Leaf(6)), Tree.Leaf(7)),
    Tree.Node(Tree.Leaf(1), Tree.Node(Tree.Leaf(2), Tree.Leaf(3))), Tree.Leaf(4),
  ]
  for tree in trees
    puts(twin(tree))
  end
  results: List[Result[Option]] = [
    Result.Ok(Option.Some(0)), Result.Ok(Option.Some(-1)), Result.Ok(Option.Some(8)), Result.Ok(Option.None),
    Result.Err("boom"), Result.Err("other"),
  ]
  for result in results
    puts(classify(result))
  end
  for n in [0, -5, 4, 40]
    puts(sign(n))
  end
end
