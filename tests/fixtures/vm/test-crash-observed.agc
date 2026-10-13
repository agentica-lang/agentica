def divide(n: Int) -> Int
  return 10 / n
end

def outside(n: Int) -> Int
  return n / 0
end

def main() -> Void
  Task.spawn(&outside, 1)
  Test.run([
    Test.test("two crashes, one reported") do
      Task.spawn(&divide, 0)
      Task.spawn(&divide, 0)
      Task.sleep(0)
      ok()
    end,
    Test.test("a leftover crashes after the test returned") do
      Task.spawn(&divide, 0)
      ok()
    end,
    Test.test("only the crash outside the tests is left") do
      puts(Task.unobserved_crash())
      ok()
    end
  ])
end
