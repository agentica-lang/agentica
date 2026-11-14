## An immutable priority queue of any type: `pop` gives the value that comes first in the order given to `new`.
##
## Every function returns a new heap and leaves the one you pass in unchanged. It is a leftist heap: `push` and `pop`
## take O(log n) steps, and `peek`, `size` and `empty?` take O(1).

## A heap. Build one with `new`.
struct Heap[T]
  ## True when the first value comes out before the second.
  before: Fn[T, T, Bool]
  ## The values.
  root: Tree[T]
  ## How many values the heap holds.
  size: Int
end

## What `pop` returns: the first value and the heap without it.
struct Popped[T]
  ## The first value.
  value: T
  ## The heap after the value was removed.
  remaining: Heap[T]
end

## Returns an empty heap. `before` is true when its first value comes out before its second: `a < b` gives the
## smallest first.
def new[T](before: Fn[T, T, Bool]) -> Heap[T] = Heap(before: before, root: Tree.Leaf, size: 0)

## Returns a heap with every value of `values` pushed, in O(n log n).
def from[T](values: List[T], before: Fn[T, T, Bool]) -> Heap[T]
  values.reduce(new(before)) do |heap, value| push(heap, value) end
end

## Returns a heap with `value` added.
def push[T](heap: Heap[T], value: T) -> Heap[T]
  single = Tree.Node(Branch(rank: 1, value: value, left: Tree.Leaf, right: Tree.Leaf))
  heap.with(root: merge(heap.before, heap.root, single), size: heap.size + 1)
end

## Takes the first value. Returns it with the rest of the heap, or an error when the heap is empty.
def pop[T](heap: Heap[T]) -> Result[Popped[T]]
  case heap.root
    Tree.Leaf -> error("heap is empty", kind: "heap.empty")
    Tree.Node(top) ->
      rest = heap.with(root: merge(heap.before, top.left, top.right), size: heap.size - 1)
      ok(Popped(value: top.value, remaining: rest))
  end
end

## Returns the first value without removing it, or an error when the heap is empty.
def peek[T](heap: Heap[T]) -> Result[T]
  case heap.root
    Tree.Leaf -> error("heap is empty", kind: "heap.empty")
    Tree.Node(top) -> ok(top.value)
  end
end

## Returns how many values are in the heap.
def size[T](heap: Heap[T]) -> Int = heap.size

## Returns true when the heap has no values.
def empty?[T](heap: Heap[T]) -> Bool = heap.size == 0

## Returns the values in the order `pop` gives them, in O(n log n).
def to_a[T](heap: Heap[T]) -> List[T]
  values: List[T] = []
  rest = heap
  while true
    case pop(rest)
      ok(popped) ->
        values = values.push(popped.value)
        rest = popped.remaining
      error(_) -> break
    end
  end

  values
end

private

struct Branch[T]
  rank: Int
  value: T
  left: Tree[T]
  right: Tree[T]
end

enum Tree[T]
  Leaf
  Node(Branch[T])
end

# Merges along the right spines, which hold O(log n) nodes, and keeps the higher rank on the left.
def merge[T](before: Fn[T, T, Bool], a: Tree[T], b: Tree[T]) -> Tree[T]
  case a
    Tree.Leaf -> b
    Tree.Node(x) ->
      case b
        Tree.Leaf -> a
        Tree.Node(y) ->
          return merge(before, b, a) if before.call(y.value, x.value)

          join(x.value, x.left, merge(before, x.right, b))
      end
  end
end

def join[T](value: T, a: Tree[T], b: Tree[T]) -> Tree[T]
  return Tree.Node(Branch(rank: rank(b) + 1, value: value, left: a, right: b)) if rank(a) >= rank(b)

  Tree.Node(Branch(rank: rank(a) + 1, value: value, left: b, right: a))
end

def rank[T](tree: Tree[T]) -> Int
  case tree
    Tree.Leaf -> 0
    Tree.Node(branch) -> branch.rank
  end
end
