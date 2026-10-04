# Immutable FIFO of Strings. This module has no native queue implementation.
export struct QueueState
  items: List[String]
end

export struct Popped
  value: String
  remaining: QueueState
end

export def new() -> QueueState
  return QueueState(items: [])
end

export def push(q: QueueState, value: String) -> QueueState
  return QueueState(items: List.append(q.items, value))
end

export def pop(q: QueueState) -> Result[Popped]
  if empty?(q)
    return error("queue is empty")
  end
  return ok(Popped(value: q.items[0], remaining: QueueState(items: List.drop(q.items, 1))))
end

export def peek(q: QueueState) -> Result[String]
  if empty?(q)
    return error("queue is empty")
  end
  return ok(q.items[0])
end

export def size(q: QueueState) -> Int
  return List.size(q.items)
end

export def empty?(q: QueueState) -> Bool
  return size(q) == 0
end
