FIRST = [1, 2]
SECOND = FIRST.push(3)
BLOCKED = [4, 5]
ONLY_BLOCK = [6]
IGNORED = [7]

def helper() -> Int
  return SECOND.size
end

def via_block() -> Int
  xs = [1]
  return xs.map do |n| n + ONLY_BLOCK[0] end.size
end

def by_ref() -> Int
  return BLOCKED.size
end

def never() -> Int
  return IGNORED.size
end

def main() -> Void
  f = &by_ref
  puts(helper() + via_block() + f.call())
end
