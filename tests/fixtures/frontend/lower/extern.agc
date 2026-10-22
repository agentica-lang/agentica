extern "/opt/lib/my peer.so"
  resource Conn, free: peer_close
  def peer_open(path: C.String) -> Conn
  def peer(a: C.Int, b: C.Bool, s: C.String) -> C.String
  def send(conn: Conn, data: C.Bytes, n: C.Int) -> C.Pointer
  def tick() -> Void
  compute def crunch(n: C.Int64) -> C.Double
end

extern "libm.so.6"
  def cos(x: C.Double) -> C.Double
end

def main() -> Void
  tick()
  puts(peer(1, cos(0.0) > 0.5, "x"))
  puts(crunch(2))
  conn = peer_open("p").unwrap!
  puts(Native.null?(send(conn, [1, 2], 2)))
  Native.close(conn)
end
