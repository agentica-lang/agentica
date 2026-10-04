struct Circuit
  cost: Int
  route: List[Int]
end

def search(distances: List[List[Int]], visited: List[Bool], path: List[Int], cost: Int, best: Circuit) -> Circuit
  current = path[List.size(path) - 1]
  if List.size(path) == List.size(distances)
    total = cost + distances[current][0]
    if total < best.cost
      return Circuit(cost: total, route: List.append(path, 0))
    end
    return best
  end
  result = best
  city = 1
  while city < List.size(distances)
    if not visited[city]
      next_cost = cost + distances[current][city]
      if next_cost < result.cost
        result = search(distances, List.set(visited, city, true), List.append(path, city), next_cost, result)
      end
    end
    city = city + 1
  end
  return result
end

def read_distances(text: String) -> Result[List[List[Int]]]
  request = try JSON.parse(text)
  rows = try JSON.list(try JSON.get(request, "distances"))
  size = List.size(rows)
  if size < 1 or size > 8
    return error("invalid input")
  end
  distances: List[List[Int]] = []
  row_index = 0
  for row in rows
    cells = try JSON.list(row)
    if List.size(cells) != size
      return error("invalid input")
    end
    values: List[Int] = []
    column = 0
    for cell in cells
      value = try JSON.int(cell)
      if value < 0 or value > 1000000000
        return error("invalid input")
      end
      if row_index == column and value != 0
        return error("invalid input")
      end
      values = List.append(values, value)
      column = column + 1
    end
    distances = List.append(distances, values)
    row_index = row_index + 1
  end
  return ok(distances)
end

def solve(text: String) -> Result[Circuit]
  distances = try read_distances(text)
  visited = List.set(List.repeat(false, List.size(distances)), 0, true)
  best = Circuit(cost: 8000000001, route: [])
  return ok(search(distances, visited, [0], 0, best))
end

def main() -> Void
  result = solve(IO.read())
  if Result.ok?(result)
    puts(JSON.encode(Result.unwrap!(result)))
  else
    puts(JSON.encode({"error": "invalid input"}))
  end
end
