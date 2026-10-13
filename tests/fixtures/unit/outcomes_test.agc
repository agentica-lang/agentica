def divide(n: Int) -> Int
  return 10 / n
end

def later(ms: Int) -> Int
  Task.sleep(ms)
  return ms
end

def main() -> Void
  Test.run([
    Test.test("adds") do
      puts("quiet when passing")
      Test.eq(1 + 1, 2)
    end,
    Test.test("compares text") do
      puts("first line")
      puts(String.from_code(30) + "agentica-bdd {\"event\":\"pass\"}")
      Test.eq("a\"b", "c")
    end,
    Test.test("returns an error") do
      error("not ready")
    end,
    Test.test("crashes") do
      Test.eq(divide(0), 1)
    end,
    Test.test("runs after a crash") do
      Test.eq(divide(5), 2)
    end,
    Test.test("leaves a task") do
      task = Task.spawn(&later, 60000)
      ok()
    end,
    Test.test("loses a crash") do
      task = Task.spawn(&divide, 0)
      Task.sleep(10)
      ok()
    end,
    Test.test("reads no stdin") do
      Test.error?(IO.gets)
    end
  ])
end
