struct Move
  dx: Int
  dy: Int
end

def scale() -> Int
  return 1
end

def destinations(size: Int, square: Int, visited: List[Bool], moves: List[Move]) -> List[Int]
  result: List[Int] = []
  for move in moves
    x = square % size + move.dx
    y = square / size + move.dy
    if x >= 0 and x < size and y >= 0 and y < size
      next = y * size + x
      if not visited[next]
        result = result.push(next)
      end
    end
  end
  return result
end

def search(size: Int, square: Int, visited: List[Bool], path: List[Int], moves: List[Move]) -> Result[List[Int]]
  marked = visited.set(square, true)
  route = path.push(square)
  if route.size == size * size
    return ok(route)
  end
  candidates = destinations(size, square, marked, moves)
  attempted = List.repeat(false, candidates.size)
  remaining = candidates.size
  while remaining > 0
    best = -1
    degree = 9
    index = 0
    for candidate in candidates
      if not attempted[index]
        exits = destinations(size, candidate, marked, moves).size
        if exits < degree
          best = index
          degree = exits
        end
      end
      index += 1
    end
    attempted = attempted.set(best, true)
    result = search(size, candidates[best], marked, route, moves)
    if result.ok?
      return result
    end
    remaining -= 1
  end
  return error("no tour")
end

def main() -> Void
  moves = [Move(dx: 1, dy: 2), Move(dx: 2, dy: 1), Move(dx: 2, dy: -1), Move(dx: 1, dy: -2), Move(dx: -1, dy: -2), Move(dx: -2, dy: -1), Move(dx: -2, dy: 1), Move(dx: -1, dy: 2)]
  size = 8
  rounds = scale()
  tours = 0
  checksum = 0
  round = 0
  while round < rounds
    start = 0
    while start < size * size
      tour = search(size, start, List.repeat(false, size * size), [], moves)
      if tour.ok?
        tours += 1
        step = 1
        for square in tour.unwrap!
          checksum = (checksum * 31 + square * step) % 1000000007
          step += 1
        end
      end
      start += 3
    end
    round += 1
  end
  puts("knight-tour #{rounds}: tours #{tours}, checksum #{checksum}")
end
