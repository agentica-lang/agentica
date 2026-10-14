def invert(n: Int) -> Result[Int]
  return ok(100 / n)
end

def halve(n: Int) -> Int
  return 100 / n
end

def main() -> Void
  failing = Task.spawn(&invert, 0)
  outcome = Task.await(failing, 10000)
  IO.inspect(outcome)
  case outcome
    Await.Done(inner) ->
      case inner
        ok(n) -> puts(n)
        error(e) -> puts("failed: #{e}")
      end
    Await.TimedOut -> puts("timed out")
  end
  puts(Task.unobserved_crash().ok?)
  IO.inspect(Task.await(failing, 1))
  plain = Task.spawn(&halve, 0)
  puts("before")
  Task.await(plain, 10000)
  puts("not reached")
end
