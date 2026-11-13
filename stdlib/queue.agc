## An immutable first-in, first-out queue of strings.
##
## Every function returns a new queue and leaves the one you pass in unchanged. The queue is a `List` underneath; there
## is no native queue.

## A queue. Build one with `new`.
struct QueueState
  ## The values, oldest first.
  items: List[String]
end

## What `pop` returns: the oldest value and the queue without it.
struct Popped
  ## The oldest value.
  value: String
  ## The queue after the value was removed.
  remaining: QueueState
end

## Returns an empty queue.
def new() -> QueueState = QueueState(items: [])

## Returns a queue with `value` added at the back.
def push(queue: QueueState, value: String) -> QueueState = QueueState(items: List.append(queue.items, value))

## Takes the oldest value. Returns it with the rest of the queue, or an error when the queue is empty.
def pop(queue: QueueState) -> Result[Popped]
  return error("queue is empty") if empty?(queue)
  ok(Popped(value: queue.items[0], remaining: QueueState(items: List.drop(queue.items, 1))))
end

## Returns the oldest value without removing it, or an error when the queue is empty.
def peek(queue: QueueState) -> Result[String]
  return error("queue is empty") if empty?(queue)
  ok(queue.items[0])
end

## Returns how many values are in the queue.
def size(queue: QueueState) -> Int = List.size(queue.items)

## Returns true when the queue has no values.
def empty?(queue: QueueState) -> Bool = size(queue) == 0
