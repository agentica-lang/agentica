def double(n: Int) -> Int
  return n * 2
end

def main() -> Nil
  handlers: Map[String, Fn[Int, Int]] = {"double": &double}
  puts(String.from_int(handlers["double"].call(21)))
end
