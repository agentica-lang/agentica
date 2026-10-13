def parse(text: String) -> Result[Int]
  n = text.to_i!
  return ok(100 / n)
end

def main() -> Void
  task = Task.spawn(&parse, "0")
  Task.sleep(0)
  puts(Task.unobserved_crash().ok?)
  case Task.await(task)
    ok(n) -> puts(n)
    error(e) -> puts("failed: #{e}")
  end
  puts(Task.unobserved_crash().ok?)
  puts(Task.await(task).ok?)
  puts(Task.pending_count())
  puts("still running")
end
