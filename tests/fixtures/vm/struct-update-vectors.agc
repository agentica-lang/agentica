struct Inner
  x: Int
  y: String
end

struct Rec
  a: Int
  b: String
  c: List[Int]
  d: Int
  e: Int
  f: String
  inner: Inner
end

struct Wide
  f0: Int
  f1: Int
  f2: Int
  f3: Int
  f4: Int
  f5: Int
  f6: Int
  f7: Int
  f8: Int
  f9: Int
  f10: Int
  f11: Int
  f12: Int
  f13: Int
  f14: Int
  f15: Int
  f16: Int
  f17: Int
  f18: Int
  f19: Int
end

def initial_rec() -> Rec
  return Rec(a: 1, b: "b", c: [], d: 4, e: 5, f: "f", inner: Inner(x: 0, y: "y"))
end

def initial_wide() -> Wide
  return Wide(f0: 0, f1: 1, f2: 2, f3: 3, f4: 4, f5: 5, f6: 6, f7: 7, f8: 8, f9: 9, f10: 10, f11: 11, f12: 12, f13: 13, f14: 14, f15: 15, f16: 16, f17: 17, f18: 18, f19: 19)
end

# Each op is one .with(...) site: other field sets, other argument orders, and values that read the old record.
def rec_op(op: Int, s: Rec, n: Int, t: String) -> Rec
  if op == 0
    return s.with(a: n)
  elsif op == 1
    return s.with(f: t)
  elsif op == 2
    return s.with(c: s.c.push(n))
  elsif op == 3
    return s.with(a: n, d: n + 1)
  elsif op == 4
    return s.with(d: n + 1, a: n)
  elsif op == 5
    return s.with(e: s.a, a: s.e)
  elsif op == 6
    return s.with(b: t + s.b, f: s.f + "!", c: [], a: s.a + n, d: 0, e: -n)
  elsif op == 7
    return s.with(inner: s.inner.with(x: n, y: t))
  end
  first = s.with(a: n)
  return first.with(d: first.d + n)
end

def wide_op(op: Int, s: Wide, n: Int) -> Wide
  if op == 0
    return s.with(f19: n)
  elsif op == 1
    return s.with(f0: n, f19: n + 1)
  elsif op == 2
    return s.with(f10: n, f3: n + 1, f17: n + 2, f0: n + 3)
  end
  return s.with(f19: s.f0, f0: s.f19, f9: s.f10 + n)
end


# Applies the steps of a line. Every step also checks that the record it started from did not change.
def run_rec(steps: String) -> String
  s = initial_rec()
  for step in steps.split(",")
    parts = step.split(":")
    before = s.to_s
    next_rec = rec_op(parts[0].to_i!, s, parts[1].to_i!, parts[2])
    if s.to_s != before
      return "the receiver changed"
    end
    s = next_rec
  end
  return s.to_s
end

def run_wide(steps: String) -> String
  s = initial_wide()
  for step in steps.split(",")
    parts = step.split(":")
    before = s.to_s
    next_wide = wide_op(parts[0].to_i!, s, parts[1].to_i!)
    if s.to_s != before
      return "the receiver changed"
    end
    s = next_wide
  end
  return s.to_s
end

def clip(text: String) -> String
  if text.length > 120
    return text.slice(0, 120)
  end
  return text
end

def check(line: String) -> Int
  f = line.split(";")
  got = ""
  if f[0] == "r"
    got = run_rec(f[1])
  else
    got = run_wide(f[1])
  end
  if got == f[2]
    return 0
  end
  puts("mismatch: " + clip(line) + ": got " + clip(got))
  return 1
end

def main() -> Void
  IO.gets()
  count = 0
  failed = 0
  running = true
  while running
    case IO.gets()
      ok(line) ->
        failed += check(line)
        count += 1
      error(message) ->
        running = false
    end
  end
  if failed == 0
    puts("#{count} vectors ok")
  else
    puts("#{failed} of #{count} vectors failed")
  end
end
