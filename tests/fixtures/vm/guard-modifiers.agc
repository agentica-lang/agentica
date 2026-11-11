# Guards: return, break and next with a trailing if, which run as the if written out.

def parse(text: String) -> Result[Int]
  return error("empty") if text.empty?
  return text.to_i
end

def first_big(xs: List[Int]) -> Int
  found = -1
  for x in xs
    next if x < 10
    found = x
    break if found > 0
  end

  return found
end

def log(text: String) -> Void
  return if text == ""
  puts(text)
end

def pick(xs: List[Int]) -> Int
  return 0 if xs.any? do |x| x < 0 end
  return xs[0] if (xs.size > 0 and not xs.include?(7)) or xs.size > 5 # a comment
  return -1
end

def main() -> Void
  puts(parse(""))
  puts(parse("42"))
  log("")
  log("shown")
  for line in ["# a", "b", "__END__", "c"]
    next if line.start_with?("#")
    break if line == "__END__"
    puts(line)
  end

  puts(first_big([1, 20, 3, 30]))
  puts(pick([1, -2]))
  puts(pick([3, 4]))
  puts(pick([7]))
  doubled = [1, 2, 3].map do |x|
    return 0 if x == 2
    x * 2
  end

  puts(doubled)
  [5, 6].each do |x| return if x == 5 end
end
