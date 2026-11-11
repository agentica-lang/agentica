def call_it(f: Fn[Int]) -> Int = f.call()

def twice(f: Fn[String, String], s: String) -> String = f.call(f.call(s))

def main() -> Void
  puts(call_it(&Time.monotonic_ms) >= 0)
  puts([1, 22, 333].map(&Int.to_s))
  puts(twice(&String.strip, "  a  "))
  puts(["a", "b"].map(&String.upcase).join(","))
  crc: Fn[Bytes, Int, Result[Int]] = &Zlib.crc32
  puts(crc.call("ab".bytes, 0).unwrap!)
  parse = &String.to_i!
  puts(parse.call("42") + 1)
  puts(parse.call("x"))
end
