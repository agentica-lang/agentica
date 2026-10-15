struct Box
  items: List[Int]
end

def main() -> Void
  n = 42
  s = "text"
  puts(n.to_s + s.to_s + s.upcase + s.length.to_s)
  puts(n.inspect)
  puts(Box(items: [1]).inspect)
  puts(s.to_s)
  puts("a,b".split(",").join("+"))
  puts([1, 2].size)
  puts(3.5.to_s)
  puts((1..3).to_a)
  puts((1..3).include?(2))
  puts(nil.to_s)
  puts(true.inspect)
end
