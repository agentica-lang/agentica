extern "/opt/lib/my peer.so"
  resource Conn, free: peer_close
  def peer_open(path: C.String) -> Conn
  def peer(a: C.Int, b: C.Bool, s: C.String) -> C.String
  def send(conn: Conn, data: C.Bytes, n: C.Int) -> C.Pointer
  def tick() -> Void
  compute def crunch(n: C.Int64) -> C.Double
  def peer_accept(port: C.Int, out conn: Conn, out count: C.Int64) -> C.Int
  def peer_split(x: C.Double, out whole: C.Double) -> Void
  def peer_pair(conn: Conn, out other: Conn) -> Conn
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
  accepted = peer_accept(80)
  puts(accepted.result + accepted.count)
  Native.close(accepted.conn)
  puts(peer_split(2.5).whole)
  pair = peer_pair(conn)
  Native.close(pair.other)
  Native.close(pair.result.unwrap!)
end
