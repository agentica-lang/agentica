import "std/queue" as Queue

def main() -> Void
  q = Queue.new()
  q = Queue.push(q, "first")
  q = Queue.push(q, "second")
  while not Queue.empty?(q)
    item = Result.unwrap!(Queue.pop(q))
    puts(item.value)
    q = item.remaining
  end
end
