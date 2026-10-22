extern "libm.so.6"
  def cos(x: C.Double) -> C.Double
end

extern "/opt/lib/my peer.so"
  def peer(a: C.Int, b: C.Bool, s: C.String) -> C.String
  def tick() -> Void
  compute def crunch(n: C.Int64) -> C.Double
end

def main() -> Void
  tick()
  puts(peer(1, cos(0.0) > 0.5, "x"))
  puts(crunch(2))
end
