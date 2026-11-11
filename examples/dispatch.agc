def double(n: Int) -> Int = n * 2

def main() -> Void
  handlers: Map[String, Fn[Int, Int]] = {"double": &double}
  puts(handlers["double"].call(21).to_s)
end
