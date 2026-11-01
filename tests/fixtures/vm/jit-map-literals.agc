# Map literals in hot loops: under --jit always (vm-jit-test, vm-gc-stress-jit) each one is the MAP code of a
# compiled function, called natively from main's loop (entry) or in the loop itself, with String, Int and Bytes keys,
# a repeated key and enough allocation for the collector to run in the middle of a literal.
def entry(k: Int) -> Map[String, Int]
  return {"a#{k % 7}": k, "b": k + 1, "c": k * 2, "b": k + 3}
end

def main() -> Void
  total = 0
  i = 0
  while i < 4000
    m = entry(i)
    n: Map[Int, String] = {i: "x#{i}", i + 1: "y", i: "z"}
    raw = {"k#{i % 3}".bytes: i}
    total = (total + m["b"] + m.size + n[i].length + n.size + raw.size) % 1000003
    i += 1
  end
  puts(total)
  puts(entry(5))
  puts({1: "one", 2: "two"})
  empty: Map[String, Int] = {}
  puts(empty.size)
end
