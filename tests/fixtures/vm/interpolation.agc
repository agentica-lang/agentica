def label(n: Int) -> String
  return "n#{n}"
end

def main() -> Void
  i = -7
  f = -0.0
  big = 1000000000000000000000.0
  b = false
  n = nil
  s = "text"
  puts("#{i}")
  puts("#{f} #{big} #{0.1 + 0.2} #{1.0 / 3.0}")
  puts("[#{b}] [#{n}] [#{s}] [#{true}]")
  puts("#{i}#{f}#{b}#{n}#{s}")
  puts("start #{i + 1} middle #{label(i)} end")
  puts("nested #{"inner #{s} #{"deep #{i}"}"} done")
  puts("#{""}#{""}")
  puts("#{s.inspect} #{i.inspect} #{f.inspect} #{b.inspect} #{n.inspect}")
  puts("#{s.to_s} #{i.to_s} #{f.to_s} #{b.to_s} #{n.to_s}")
  puts(i.to_s.inspect)
  puts(b.to_s + n.to_s)
  puts(s.to_s.to_s)
  puts("#{i}".inspect.inspect)
  t = "#{s}!"
  t = "#{t}#{t}"
  puts(t)
  puts(true.inspect)
  puts(nil.to_s)
  puts(3.5.inspect)
end
