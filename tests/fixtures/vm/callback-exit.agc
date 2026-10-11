def main() -> Void
  [1, 2, 3].each do |x|
    puts("item #{x}")
    if x == 2
      System.exit(7)
    end
  end
  puts("not reached")
end
