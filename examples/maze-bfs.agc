struct Maze
  width: Int
  height: Int
  cells: Map[Int, Bool]
  start: Int
  goal: Int
end

struct Route
  found: Bool
  distance: Int
  path: List[Int]
end

def read_maze(text: String) -> Result[Maze]
  request = try JSON.parse(text)
  rows = try JSON.list(try JSON.get(request, "grid"))
  height = List.size(rows)
  if height < 1 or height > 32
    return error("invalid input")
  end
  width = 0
  cells: Map[Int, Bool] = {}
  row_index = 0
  for row in rows
    line = try JSON.string(row)
    if row_index == 0
      width = String.length(line)
    end
    if width < 1 or width > 32 or String.length(line) != width
      return error("invalid input")
    end
    column = 0
    for cell in String.split(line, "")
      if cell == "."
        cells = Map.put(cells, row_index * width + column, true)
      elsif cell != "#"
        return error("invalid input")
      end
      column = column + 1
    end
    row_index = row_index + 1
  end
  start = try JSON.int(try JSON.get(request, "start"))
  goal = try JSON.int(try JSON.get(request, "goal"))
  if start < 0 or start >= width * height or goal < 0 or goal >= width * height
    return error("invalid input")
  end
  if not Map.get(cells, start, false) or not Map.get(cells, goal, false)
    return error("invalid input")
  end
  return ok(Maze(width: width, height: height, cells: cells, start: start, goal: goal))
end

def neighbors(maze: Maze, square: Int) -> List[Int]
  x = square % maze.width
  y = square / maze.width
  result: List[Int] = []
  if y > 0
    result = List.append(result, square - maze.width)
  end
  if x + 1 < maze.width
    result = List.append(result, square + 1)
  end
  if y + 1 < maze.height
    result = List.append(result, square + maze.width)
  end
  if x > 0
    result = List.append(result, square - 1)
  end
  return result
end

def reconstruct(start: Int, goal: Int, previous: Map[Int, Int]) -> List[Int]
  path: List[Int] = []
  current = goal
  while current != start
    path = List.append(path, current)
    current = Result.unwrap!(Map.get(previous, current))
  end
  return List.reverse(List.append(path, start))
end

def shortest_route(maze: Maze) -> Route
  queue: Map[Int, Int] = {}
  queue = Map.put(queue, 0, maze.start)
  distances: Map[Int, Int] = {}
  distances = Map.put(distances, maze.start, 0)
  previous: Map[Int, Int] = {}
  head = 0
  tail = 1
  while Map.size(queue) > 0
    current = Result.unwrap!(Map.get(queue, head))
    queue = Map.delete(queue, head)
    head = head + 1
    distance = Result.unwrap!(Map.get(distances, current))
    if current == maze.goal
      return Route(found: true, distance: distance, path: reconstruct(maze.start, maze.goal, previous))
    end
    for next in neighbors(maze, current)
      if Map.get(maze.cells, next, false) and not Result.ok?(Map.get(distances, next))
        distances = Map.put(distances, next, distance + 1)
        previous = Map.put(previous, next, current)
        queue = Map.put(queue, tail, next)
        tail = tail + 1
      end
    end
  end
  return Route(found: false, distance: -1, path: [])
end

def main() -> Nil
  maze = read_maze(IO.read())
  if Result.ok?(maze)
    puts(JSON.encode(shortest_route(Result.unwrap!(maze))))
  else
    puts(JSON.encode({"error": "invalid input"}))
  end
end
