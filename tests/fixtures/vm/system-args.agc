def main() -> Void
  args = System.args()
  count = 0
  for arg in args
    puts("#{count} #{arg.inspect}")
    count = count + 1
  end
  puts(args)
end
