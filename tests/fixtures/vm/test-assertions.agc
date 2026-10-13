struct Point
  x: Int
  tags: List[String]
end

enum Shape
  Dot
  Square(Int)
end

def parse(text: String) -> Result[Int]
  return text.to_i
end

def divide(n: Int) -> Int
  return 10 / n
end

def later(ms: Int) -> Int
  Task.sleep(ms)
  puts("never printed")
  return ms
end

def check_in_task(n: Int) -> Result[Void]
  return Test.eq(n, 4)
end

def main() -> Void
  outside = Test.eq(1, 2)
  puts("outside a test: #{outside.message}")
  Test.run([
    Test.test("values are equal") do
      try Test.eq([1, 2], [1, 2])
      try Test.eq({"a": 1, "b": 2}, {"b": 2, "a": 1})
      try Test.eq(Point(x: 1, tags: ["a"]), Point(x: 1, tags: ["a"]))
      try Test.eq(Shape.Square(2), Shape.Square(2))
      try Test.ok?(parse("80"))
      try Test.error?(parse("x"))
      Test.assert(1 < 2, "one is below two")
    end,
    Test.test("a struct differs") do
      try Test.eq(Point(x: 1, tags: ["a"]), Point(x: 2, tags: ["b"]))
      puts("not reached")
      ok()
    end,
    Test.test("a Result differs") do
      Test.eq(parse("x"), ok(80))
    end,
    Test.test("ok? fails") do
      Test.ok?(parse("x"))
    end,
    Test.test("error? fails") do
      Test.error?(parse("0"))
    end,
    Test.test("assert fails") do
      Test.assert(2 < 1, "two is not below one")
    end,
    Test.test("an ignored failure still fails") do
      Test.eq("a", "b")
      Test.eq(1, 3)
      ok()
    end,
    Test.test("the block returns an error") do
      error("not ready")
    end,
    Test.test("a crash fails only this test") do
      puts(divide(0))
      ok()
    end,
    Test.test("the next test still runs") do
      Test.eq(divide(5), 2)
    end,
    Test.test("pending tasks") do
      Task.spawn(&later, 50)
      ok()
    end,
    Test.test("an unobserved crash") do
      Task.spawn(&divide, 0)
      Task.sleep(0)
      ok()
    end,
    Test.test("an assertion in a spawned task") do
      Task.await(Task.spawn(&check_in_task, 3))
      ok()
    end,
    Test.test("Test.run inside a test") do
      Test.run([])
      ok()
    end,
    Test.test("Json compares as canonical text") do
      a = JSON.parse("{\"b\": 1, \"a\": [true, null]}").unwrap!
      b = JSON.parse("{\"a\":[true,null],\"b\":1}").unwrap!
      try Test.eq(a, b)
      try Test.eq([a, JSON.from(1)], [b, JSON.from(1)])
      Test.eq([a], [JSON.from(1.5)])
    end
  ])
end
