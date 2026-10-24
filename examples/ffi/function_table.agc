# Dispatch through a table of C function pointers, the shape runtimes like
# onnxruntime's OrtApi use: one call returns the table (NULL for a version the
# library does not know), each slot holds one typed function, and a declared
# first `fn: C.Function` parameter calls it. Slot 0 needs no size assumption.
ADD = 0
SCALE = 1

extern "demo"
  def demo_api_table(version: C.Int32) -> C.Pointer
  def demo_version() -> C.String
  def add(fn: C.Function, a: C.Int32, b: C.Int32) -> C.Int32
  def scale(fn: C.Function, x: C.Double, k: C.Double) -> C.Double
end

def slot(table: C.Pointer, index: Int) -> C.Pointer
  return Native.get_pointer(table, index * 8)
end

def main() -> Void
  table = demo_api_table(1)
  if Native.null?(table)
    puts("no table for version 1")
  else
    puts(add(slot(table, ADD), 40, 2))
    puts(scale(slot(table, SCALE), 1.5, -2.0))
  end
  puts(Native.null?(demo_api_table(2)))
  puts(demo_version())
end
