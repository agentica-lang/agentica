import Queue from "std/queue"

def main() -> Void
  q = Queue.push(Queue.push(Queue.new(), "a"), "b")
  puts(Queue.size(q))
  puts(Queue.peek(q))
  popped = Result.unwrap!(Queue.pop(q))
  puts("#{popped.value} #{popped.remaining}")
  IO.inspect(Queue.pop(Queue.new()))
  puts(Queue.empty?(popped.remaining))
end
