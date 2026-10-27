## A generic struct that another file imports: the type parameter stays local, in the fields and the default.

export struct Stack[T]
  items: List[T] = []
  label: String = "stack"
end

export def single(item: Int) -> Stack[Int]
  return Stack(items: [item])
end

export def push(stack: Stack[Int], item: Int) -> Stack[Int]
  return stack.with(items: stack.items.push(item))
end
