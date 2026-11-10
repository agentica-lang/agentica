## An immutable first-in, first-out queue of strings.
##
## Every function returns a new queue and leaves the one you pass in unchanged. The queue is a `List` underneath; there
## is no native queue.

## A queue. Build one with `new`.
export struct QueueState
  ## The values, oldest first.
  items: List[String]
end

## What `pop` returns: the oldest value and the queue without it.
export struct Popped
  ## The oldest value.
  value: String
  ## The queue after the value was removed.
  remaining: QueueState
end

## Returns an empty queue.
export def new() -> QueueState = QueueState(items: [])

## Returns a queue with `value` added at the back.
export def push(q: QueueState, value: String) -> QueueState = QueueState(items: List.append(q.items, value))

## Takes the oldest value. Returns it with the rest of the queue, or an error when the queue is empty.
export def pop(q: QueueState) -> Result[Popped]
  return error("queue is empty") if empty?(q)
  return ok(Popped(value: q.items[0], remaining: QueueState(items: List.drop(q.items, 1))))
end

## Returns the oldest value without removing it, or an error when the queue is empty.
export def peek(q: QueueState) -> Result[String]
  return error("queue is empty") if empty?(q)
  return ok(q.items[0])
end

## Returns how many values are in the queue.
export def size(q: QueueState) -> Int = List.size(q.items)

## Returns true when the queue has no values.
export def empty?(q: QueueState) -> Bool = size(q) == 0
