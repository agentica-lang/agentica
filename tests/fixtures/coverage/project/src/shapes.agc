def area(kind: String, side: Int) -> Int
  if kind == "square"
    return side * side
  elsif kind == "triangle"
    return (side * side) / 2
  end

  return 0
end

def unused() -> Int
  return 1
end
