import Heap from "std/heap"

def main() -> Void
  Test.run([
    Test.test("a new heap is empty") do
      h = Heap.new do |a: Int, b: Int| a < b end
      try Test.eq(Heap.size(h), 0)
      try Test.assert(Heap.empty?(h), "a new heap is empty")
      try Test.eq(Heap.peek(h), error("heap is empty", kind: "heap.empty"))
      Test.error?(Heap.pop(h))
    end,
    Test.test("values leave in the order of before") do
      h = Heap.from([5, 1, 4, 1, 3]) do |a: Int, b: Int| a < b end
      try Test.eq(Heap.peek(h), ok(1))
      try Test.eq(Heap.to_a(h), [1, 1, 3, 4, 5])
      largest = Heap.from(["pear", "fig", "apple"]) do |a: String, b: String| a.compare(b) > 0 end
      first = try Heap.pop(largest)
      try Test.eq(first.value, "pear")
      Test.eq(Heap.to_a(first.remaining), ["fig", "apple"])
    end,
    Test.test("many values come out sorted") do
      values = (1..2000).map do |i| (i * 7919) % 2003 end
      h = Heap.from(values) do |a: Int, b: Int| a < b end
      try Test.eq(Heap.size(h), 2000)
      Test.eq(Heap.to_a(h), values.sort)
    end,
    Test.test("a non-strict order with repeated values ends") do
      h = Heap.from([2, 2, 1, 2, 1]) do |a: Int, b: Int| a <= b end
      Test.eq(Heap.to_a(h), [1, 1, 2, 2, 2])
    end,
    Test.test("values that tie all come out") do
      jobs = [["b", "1"], ["a", "2"], ["c", "1"], ["d", "2"]]
      h = Heap.from(jobs) do |a: List[String], b: List[String]| a[1].compare(b[1]) < 0 end
      out = Heap.to_a(h)
      try Test.eq(out.map do |job| job[1] end, ["1", "1", "2", "2"])
      names = out.map do |job| job[0] end
      Test.eq(names.sort, ["a", "b", "c", "d"])
    end,
    Test.test("push and pop leave the old heap unchanged") do
      h = Heap.push(Heap.new(->(a: Int, b: Int) { a < b }), 2)
      smaller = Heap.push(h, 1)
      popped = try Heap.pop(smaller)
      try Test.eq(Heap.to_a(h), [2])
      try Test.eq(Heap.to_a(smaller), [1, 2])
      Test.eq(Heap.to_a(popped.remaining), [2])
    end,
  ])
end
