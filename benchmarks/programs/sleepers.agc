def scale() -> Int
  return 1
end

def nap(index: Int) -> Int
  total = 0
  k = 0
  while k < 10
    Task.sleep(1)
    total += index + k
    k += 1
  end
  return total
end

def quick(index: Int) -> Int
  return index * 3 + 1
end

# Phase one: many tasks sleep at once (many armed timers). Phase two: each await has a long deadline that the finished
# task cancels (an arm and a disarm per await, nothing ever fires).
def main() -> Void
  total = 0
  round = 0
  while round < 2 * scale()
    tasks: List[Task[Int]] = []
    i = 0
    while i < 100
      tasks = tasks.push(Task.spawn(&nap, i))
      i += 1
    end
    for t in tasks
      total += Task.await(t)
    end
    j = 0
    while j < 3000
      case Task.await(Task.spawn(&quick, j), 60000)
        Await.Done(v) -> total += v
        Await.TimedOut -> total -= 1
      end
      j += 1
    end
    round += 1
  end
  puts("sleepers #{2 * scale()}: checksum #{total}")
end
