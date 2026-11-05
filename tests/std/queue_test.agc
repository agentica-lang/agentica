import Queue from "std/queue"

def main() -> Void
  Test.run([
    Test.test("a new queue is empty") do
      q = Queue.new()
      try Test.eq(Queue.size(q), 0)
      try Test.assert(Queue.empty?(q), "a new queue is empty")
      try Test.eq(Queue.peek(q), error("queue is empty"))
      Test.error?(Queue.pop(q))
    end,
    Test.test("values leave in the order they came") do
      q = Queue.push(Queue.push(Queue.new(), "a"), "b")
      try Test.eq(Queue.size(q), 2)
      try Test.eq(Queue.peek(q), ok("a"))
      first = try Queue.pop(q)
      try Test.eq(first.value, "a")
      second = try Queue.pop(first.remaining)
      try Test.eq(second.value, "b")
      Test.assert(Queue.empty?(second.remaining), "the queue is empty after two pops")
    end,
    Test.test("push leaves the old queue unchanged") do
      q = Queue.push(Queue.new(), "a")
      longer = Queue.push(q, "b")
      try Test.eq(Queue.size(q), 1)
      Test.eq(Queue.size(longer), 2)
    end
  ])
end
