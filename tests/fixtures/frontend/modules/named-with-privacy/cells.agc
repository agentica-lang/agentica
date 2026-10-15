export struct Cell
  n: Int
end

export struct Other
  n: Int
end

struct Secret
  n: Int
end

export def cell() -> Cell
  return Cell(n: 1)
end
