export TOP = 100
export NAMES = ["a", "b"]
PRIVATE = NAMES.size

export def top() -> Int
  return TOP + PRIVATE
end

def unused() -> Int
  return PRIVATE
end
