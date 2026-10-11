struct Circuit
  cost: Int
  route: List[Int]
end

def scale() -> Int
  return 1
end

def search(distances: List[List[Int]], visited: List[Bool], path: List[Int], cost: Int, best: Circuit) -> Circuit
  current = path[path.size - 1]
  if path.size == distances.size
    total = cost + distances[current][0]
    if total < best.cost
      return Circuit(cost: total, route: path.push(0))
    end
    return best
  end
  result = best
  city = 1
  while city < distances.size
    if not visited[city]
      next_cost = cost + distances[current][city]
      if next_cost < result.cost
        result = search(distances, visited.set(city, true), path.push(city), next_cost, result)
      end
    end
    city += 1
  end
  return result
end

def make_distances(count: Int, seed: Int) -> List[List[Int]]
  xs: List[Int] = []
  ys: List[Int] = []
  state = seed
  i = 0
  while i < count
    state = (state * 1103515245 + 12345) % 2147483648
    xs = xs.push(state / 65536 % 1000)
    state = (state * 1103515245 + 12345) % 2147483648
    ys = ys.push(state / 65536 % 1000)
    i += 1
  end
  rows: List[List[Int]] = []
  for a in List.take([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], count)
    row: List[Int] = []
    for b in List.take([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], count)
      dx = xs[a] - xs[b]
      dy = ys[a] - ys[b]
      if dx < 0
        dx = -dx
      end
      if dy < 0
        dy = -dy
      end
      row = row.push(dx + dy)
    end
    rows = rows.push(row)
  end
  return rows
end

def main() -> Void
  rounds = scale()
  cities = 9
  checksum = 0
  round = 0
  while round < rounds
    distances = make_distances(cities, round + 7)
    visited = List.repeat(false, cities).set(0, true)
    best = search(distances, visited, [0], 0, Circuit(cost: 1000000000, route: []))
    puts("round #{round}: cost #{best.cost}, route #{best.route}")
    checksum = (checksum * 31 + best.cost) % 1000000007
    round += 1
  end
  puts("traveling-salesman #{rounds}: checksum #{checksum}")
end
