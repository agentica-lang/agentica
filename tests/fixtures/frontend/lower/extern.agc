extern "/opt/lib/my peer.so"
  resource Conn, free: peer_close
  def peer_open(path: C.String) -> Conn
  def peer(a: C.Int32, b: C.Bool, s: C.String) -> C.String
  def send(conn: Conn, data: C.Bytes, n: C.Int32) -> C.Pointer
  def tick() -> Void
  def peer_narrow(a: C.Int8, b: C.UInt16, out c: C.UInt32) -> C.Long
  compute def crunch(n: C.Int64) -> C.Double
  def peer_accept(port: C.Int32, out conn: Conn, out count: C.Int64) -> C.Int32
  def peer_split(x: C.Double, out whole: C.Double) -> Void
  def peer_pair(conn: Conn, out other: Conn) -> Conn
  resource Cap, free: PeerFree
  def peer_cap() -> Cap
  resource Session, free: C.Function
  def peer_at(fn: C.Function, x: C.Int32) -> C.Int32
  compute def session_open(fn: C.Function, path: C.String, out s: Session, free: C.Function) -> C.Int32
  def session_named(path: C.String, free: C.Function) -> Session
  struct Pair
    x: C.Int32
    y: C.Int64 = 0
  end
  struct Box
    at: Pair
    scale: C.Float
    on: C.Bool
    data: C.Pointer
    count: C.UInt32
  end
  def box_make(n: C.Int64) -> Box
  compute def box_area(fn: C.Function, b: Box, p: Pair, out area: C.Double) -> Box
  callback Visit(arg: C.Pointer, n: C.Int32, name: C.String) -> C.Double
  def peer_walk(visit: Visit, arg: C.Pointer) -> C.Int32
end

extern "libm.so.6"
  def cos(x: C.Double) -> C.Double
end

def main() -> Void
  tick()
  narrow = peer_narrow(-1, 65_535)
  puts(narrow.result + narrow.c)
  puts(peer(1, cos(0.0) > 0.5, "x"))
  puts(crunch(2))
  conn = peer_open("p").unwrap!
  puts(Native.null?(send(conn, "ab".bytes, 2)))
  Native.close(conn)
  accepted = peer_accept(80)
  puts(accepted.result + accepted.count)
  Native.close(accepted.conn)
  puts(peer_split(2.5).whole)
  pair = peer_pair(conn)
  Native.close(pair.other)
  Native.close(pair.result.unwrap!)
  Native.close(peer_cap().unwrap!)
  table = Native.memory_pointer(16)
  puts(peer_at(Native.get_pointer(table, 0), 1))
  opened = session_open(Native.get_pointer(table, 8), "s", Native.get_pointer(table, 0))
  Native.close(opened.s)
  Native.close(session_named("t", Native.get_pointer(table, 0)).unwrap!)
  box = box_make(3)
  boxed = box_area(Native.get_pointer(table, 0), box.with(on: true), Pair(x: 1))
  puts(boxed.area + boxed.result.at.y.to_f)
  visit = Native.callback(Visit, &visit_one)
  puts(peer_walk(visit, table))
  Native.close(visit)
end

def visit_one(arg: C.Pointer, n: Int, name: String) -> Float
  return n.to_f
end
