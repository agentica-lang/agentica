struct Gen
  name: String
  make: Fn[Int, Int]
end

def add(a: Int, b: Int, c: Int) -> Int = a + b + c

def apply_twice(f: Fn[Int, Int], x: Int) -> Int = f.call(f.call(x))

def compose[A, B, C](f: Fn[A, B], g: Fn[B, C], x: A) -> C = g.call(f.call(x))

def adder(n: Int) -> Fn[Int, Int] = ->(x) { x + n }

# A function of the program wins over the method of the same name, so `xs |> first()` calls this one.
def first(xs: List[Int]) -> String = "first of #{xs.size}"

def parse_double(text: String) -> Result[Int]
  doubled: Fn[String, Result[Int]] = ->(s) {
    n = try s.to_i
    ok(n * 2)
  }

  doubled.call(text)
end

def main() -> Void
  c = 100
  f: Fn[Int, Int, Int] = ->(a, b) { add(a, b, c) }
  puts(f.call(1, 2))

  base = 10
  inc = ->(x: Int) { x + base }
  puts(inc.call(5))

  answer = -> { 42 }
  puts(answer.call())

  gen = Gen(name: "next", make: ->(seed) { seed + 1 })
  puts("#{gen.name} #{gen.make(1)}")

  ops: Map[String, Fn[Int, Int, Int]] = {"add": ->(a, b) { a + b }, "sub": ->(a, b) { a - b }}
  puts(ops["add"].call(2, 3))
  puts(ops["sub"].call(2, 3))

  steps = [->(x: Int) { x + 1 }, ->(x: Int) { x * 3 }]
  puts(steps.map do |step| step.call(2) end)

  puts(apply_twice(->(x) { x * x }, 3))
  puts(compose(->(n) { "#{n}!" }, ->(s) { s.length }, 12345))
  puts(adder(7).call(1))

  sign = ->(x: Int) {
    return "negative" if x < 0

    "not negative"
  }

  puts(sign.call(-3))
  puts(sign.call(4))

  curried: Fn[Int, Fn[Int, Int]] = ->(a) { ->(b) { a * 10 + b } }
  puts(curried.call(4).call(2))

  labels = [1, 2].map do |n|
    label = ->(suffix: String) { "#{n}#{suffix}" }
    label.call("st")
  end

  puts(labels)

  puts(parse_double("21"))
  puts(parse_double("x"))

  xs = [1, 2, 3]
  puts(xs.map(->(x) { x * 2 }).sum)
  total = (
    xs
    |> map(->(x) { x * 2 })
    |> select(->(x) { x > 2 })
    |> sum()
  )

  puts(total)
  xs |> each(->(x) { puts(x * c) })
  puts(xs |> reduce(0, ->(acc, x) { acc + x }))
  {"a": 1, "b": 2} |> each(->(key, value) { puts("#{key}=#{value}") })
  puts(xs |> first())
  puts(xs.first)
end
