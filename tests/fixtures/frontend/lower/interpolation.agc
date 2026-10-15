def main() -> Void
  name = "x"
  n = 3
  f = 1.5
  puts("#{name}")
  puts("#{n}#{f}#{name}!")
  puts("a #{n + 1} b #{[n]} c #{name == "x"}")
  puts("#{"nested #{n}"} end")
  lines = ["l1", "l2"]
  puts("#{lines}")
end
