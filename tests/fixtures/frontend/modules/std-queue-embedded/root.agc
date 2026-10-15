import "std/queue" as Queue
import "std/queue" as Again
def main() -> Void
  original = Queue.new()
  q: Again.QueueState = Queue.push(original, "")
  q = Queue.push(q, "same")
  q = Queue.push(q, "same")
  IO.inspect(Queue.size(q))
  IO.inspect(Queue.empty?(original))
  IO.inspect(not Result.ok?(Queue.pop(original)))
  IO.inspect(not Result.ok?(Queue.peek(original)))
  IO.inspect(Result.unwrap!(Queue.peek(q)))
  while not Queue.empty?(q)
    item = Result.unwrap!(Queue.pop(q))
    puts(item.value)
    q = item.remaining
  end
  IO.inspect(Queue.size(q))
end

