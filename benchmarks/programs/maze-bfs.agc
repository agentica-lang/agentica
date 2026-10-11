struct Maze
  width: Int
  height: Int
  cells: Map[Int, Bool]
end

def scale() -> Int
  return 1
end

def make_maze(width: Int, height: Int, seed: Int) -> Maze
  cells: Map[Int, Bool] = {}
  state = seed
  square = 0
  while square < width * height
    state = (state * 1103515245 + 12345) % 2147483648
    if state / 65536 % 100 < 70 or square == 0 or square == width * height - 1
      cells = cells.put(square, true)
    end
    square += 1
  end
  return Maze(width: width, height: height, cells: cells)
end

def neighbors(maze: Maze, square: Int) -> List[Int]
  x = square % maze.width
  y = square / maze.width
  result: List[Int] = []
  if y > 0
    result = result.push(square - maze.width)
  end
  if x + 1 < maze.width
    result = result.push(square + 1)
  end
  if y + 1 < maze.height
    result = result.push(square + maze.width)
  end
  if x > 0
    result = result.push(square - 1)
  end
  return result
end

def path_length(start: Int, goal: Int, previous: Map[Int, Int]) -> Int
  length = 0
  current = goal
  while current != start
    current = previous[current]
    length += 1
  end
  return length
end

def shortest(maze: Maze, start: Int, goal: Int) -> Int
  queue: Map[Int, Int] = {start: start}
  head = 0
  tail = 1
  distances: Map[Int, Int] = {start: 0}
  previous: Map[Int, Int] = {}
  while head < tail
    current = queue[head]
    queue = queue.delete(head)
    head += 1
    if current == goal
      return path_length(start, goal, previous)
    end
    distance = distances[current]
    for next in neighbors(maze, current)
      if maze.cells.get(next, false) and not distances.has_key?(next)
        distances = distances.put(next, distance + 1)
        previous = previous.put(next, current)
        queue = queue.put(tail, next)
        tail += 1
      end
    end
  end
  return -1
end

def main() -> Void
  rounds = 4 * scale()
  width = 40
  height = 40
  checksum = 0
  solved = 0
  round = 0
  while round < rounds
    maze = make_maze(width, height, round + 1)
    distance = shortest(maze, 0, width * height - 1)
    if distance >= 0
      solved += 1
    end
    checksum = checksum * 1000 + distance + 1
    checksum %= 1000000007
    round += 1
  end
  puts("maze-bfs #{rounds}: solved #{solved}, checksum #{checksum}")
end
