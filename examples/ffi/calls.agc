# Plain native calls: typed extern functions of the demo library, checked and
# run like any other function. `demo_total_upto` is a compute def, so a large
# input would run on the compute pool while other tasks keep running; the demo
# input stays small.
extern "demo"
  def demo_add(a: C.Int32, b: C.Int32) -> C.Int32
  def demo_scale(x: C.Double, k: C.Double) -> C.Double
  compute def demo_total_upto(n: C.Int64) -> C.Int64
end

def main() -> Void
  puts(demo_add(40, 2))
  puts(demo_scale(1.5, -2.0))
  puts(demo_total_upto(100))
end
