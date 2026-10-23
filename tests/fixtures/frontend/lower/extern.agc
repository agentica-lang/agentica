extern "/opt/lib/my peer.so"
  resource Conn, free: peer_close
  def peer_open(path: C.String) -> Conn
  def peer(a: C.Int32, b: C.Bool, s: C.String) -> C.String
  def send(conn: Conn, data: C.Bytes, n: C.Int32) -> C.Pointer
  def tick() -> Void
  compute def crunch(n: C.Int64) -> C.Double
  def peer_accept(port: C.Int32, out conn: Conn, out count: C.Int64) -> C.Int32
  def peer_split(x: C.Double, out whole: C.Double) -> Void
  def peer_pair(conn: Conn, out other: Conn) -> Conn
  resource Session, free: C.Function
  def peer_at(fn: C.Function, x: C.Int32) -> C.Int32
  compute def session_open(fn: C.Function, path: C.String, out s: Session, free: C.Function) -> C.Int32
  def session_named(path: C.String, free: C.Function) -> Session
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
  table = Native.memory_pointer(16)
  puts(peer_at(Native.get_pointer(table, 0), 1))
  opened = session_open(Native.get_pointer(table, 8), "s", Native.get_pointer(table, 0))
  Native.close(opened.s)
  Native.close(session_named("t", Native.get_pointer(table, 0)).unwrap!)
end
