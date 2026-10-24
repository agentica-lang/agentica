# Structs by value, an owned resource, and a caller-owned buffer: the shapes a
# numeric C API uses. The struct crosses by value, the accumulator lives in C
# and is freed by its destructor (never by malloc/free in Agentica), and the
# float buffer is Agentica memory that C fills and reads.
extern "demo"
  struct DemoPair
    x: C.Int32
    y: C.Int32
  end
  resource Acc, free: demo_acc_close
  def demo_pair_make(x: C.Int32, y: C.Int32) -> DemoPair
  def demo_pair_swap(pair: DemoPair) -> DemoPair
  def demo_pair_sum(pair: DemoPair) -> C.Int64
  def demo_acc_open(start: C.Int64) -> Acc
  def demo_acc_add(acc: Acc, delta: C.Int32) -> Void
  def demo_acc_get(acc: Acc) -> C.Int64
  def demo_fill_floats(out: C.Pointer, n: C.Int32) -> Void
  def demo_sum_floats(xs: C.Pointer, n: C.Int32) -> C.Double
end

def main() -> Void
  pair = demo_pair_make(3, 4)
  puts(demo_pair_sum(demo_pair_swap(pair)))
  acc = demo_acc_open(10).unwrap!
  demo_acc_add(acc, 5)
  demo_acc_add(acc, -2)
  puts(demo_acc_get(acc))
  Native.close(acc)
  IO.inspect(demo_acc_open(-1))
  total = Native.memory_pointer(16) do |buf|
    demo_fill_floats(buf, 4)
    demo_sum_floats(buf, 4)
  end
  puts(total)
end
