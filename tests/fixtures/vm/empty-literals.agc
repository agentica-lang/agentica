# `[]` and `{}` with no items return one shared empty value in the VM. Everything that builds on one must leave it
# empty: the values are persistent, so a put or a push gives a new value, and tasks read the same empties.
def grow(n: Int) -> Map[Int, Int]
  table: Map[Int, Int] = {}
  i = 0
  while i < n
    table = table.put(i, i * i)
    i += 1
  end
  return table
end

def fill(n: Int) -> List[Int]
  items: List[Int] = []
  i = 0
  while i < n
    items = items.push(i)
    i += 1
  end
  return items
end

def in_task(n: Int) -> String
  return "#{grow(n)} #{fill(n)}"
end

def main() -> Void
  puts(grow(3))
  puts(grow(0))
  puts(grow(2))
  puts(fill(2))
  puts(fill(0))
  puts(fill(3))

  base: Map[String, Int] = {}
  with_x = base.put("x", 1)
  with_y = base.put("y", 2)
  puts(base)
  puts(with_x)
  puts(with_y)
  puts(base.size)

  empty: List[Int] = []
  more = empty.push(1)
  puts(empty)
  puts(more)
  puts(empty.push(2))
  puts(empty.size)

  puts(base.keys)
  puts(empty.concat([1, 2]))
  puts(empty.concat(empty))

  first = Task.spawn(&in_task, 2)
  second = Task.spawn(&in_task, 0)
  third = Task.spawn(&in_task, 1)
  puts(Task.await(first))
  puts(Task.await(second))
  puts(Task.await(third))
  puts(base)
  puts(empty)
end
