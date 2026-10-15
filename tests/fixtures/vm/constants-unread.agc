SAFE = [1, 2, 3]
BROKEN = SAFE[9]
ALSO_BROKEN = BROKEN + 1

def never() -> Int
  return ALSO_BROKEN
end

def main() -> Void
  puts(SAFE.size)
  puts(main_is_not_recursive())
end

def main_is_not_recursive() -> String
  return "done"
end
