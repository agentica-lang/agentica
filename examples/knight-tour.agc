struct Move
  dx: Int
  dy: Int
end

struct Tour
  found: Bool
  path: List[Int]
end

def destinations(size: Int, square: Int, visited: List[Bool]) -> List[Int]
  moves = [Move(dx: 1, dy: 2), Move(dx: 2, dy: 1), Move(dx: 2, dy: -1), Move(dx: 1, dy: -2), Move(dx: -1, dy: -2), Move(dx: -2, dy: -1), Move(dx: -2, dy: 1), Move(dx: -1, dy: 2)]
  result: List[Int] = []
  for move in moves
    x = square % size + move.dx
    y = square / size + move.dy
    if x >= 0 and x < size and y >= 0 and y < size
      next = y * size + x
      if not visited[next]
        result = List.append(result, next)
      end
    end
  end
  result
end

def search(size: Int, square: Int, visited: List[Bool], path: List[Int]) -> Result[List[Int]]
  marked = List.set(visited, square, true)
  route = List.append(path, square)
  return ok(route) if List.size(route) == size * size
  candidates = destinations(size, square, marked)
  attempted = List.repeat(false, List.size(candidates))
  remaining = List.size(candidates)
  while remaining > 0
    best = -1
    degree = 9
    index = 0
    for candidate in candidates
      if not attempted[index]
        exits = List.size(destinations(size, candidate, marked))
        if exits < degree
          best = index
          degree = exits
        end
      end
      index = index + 1
    end
    attempted = List.set(attempted, best, true)
    result = search(size, candidates[best], marked, route)
    return result if Result.ok?(result)
    remaining = remaining - 1
  end
  error("no tour")
end

def solve(text: String) -> Result[Tour]
  request = try JSON.parse(text)
  size = try JSON.int(try JSON.get(request, "size"))
  start = try JSON.int(try JSON.get(request, "start"))
  return error("invalid input") if size < 1 or size > 8
  return error("invalid input") if start < 0 or start >= size * size
  result = search(size, start, List.repeat(false, size * size), [])
  return ok(Tour(found: true, path: Result.unwrap!(result))) if Result.ok?(result)
  ok(Tour(found: false, path: []))
end

def main() -> Void
  result = solve(IO.read())
  if Result.ok?(result)
    puts(JSON.encode(Result.unwrap!(result)))
  else
    puts(JSON.encode({"error": "invalid input"}))
  end
end
