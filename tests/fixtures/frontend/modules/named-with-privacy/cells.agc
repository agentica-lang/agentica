struct Cell
  n: Int
end

struct Other
  n: Int
end

def cell() -> Cell
  return Cell(n: 1)
end

private

struct Secret
  n: Int
end
