def scale() -> Int
  return 1
end

def nap(index: Int) -> Int
  total = 0
  for k in 0...10
    Task.sleep(1)
    total += index + k
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
  rounds = 2 * scale()
  for _ in 0...rounds
    tasks: List[Task[Int]] = []
    for i in 0...100
      tasks = tasks.push(Task.spawn(&nap, i))
    end
    for t in tasks
      total += Task.await(t)
    end
    for j in 0...3000
      case Task.await(Task.spawn(&quick, j), 60000)
        Await.Done(v) -> total += v
        Await.TimedOut -> total -= 1
      end
    end
  end
  puts("sleepers #{rounds}: checksum #{total}")
end
