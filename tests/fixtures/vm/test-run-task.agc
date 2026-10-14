def serve(n: Int) -> Int
  Test.run([
    Test.test("served from a task") do
      puts("inside the test")
      ok()
    end
  ])
  return n
end

def main() -> Void
  task = Task.spawn(&serve, 1)
  puts(Task.await(task))
end
