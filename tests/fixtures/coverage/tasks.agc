# The tasks program of tests/test_cli_coverage.py: four tasks that run at the same time on several schedulers, each
# long enough to span many turns, so the counters are added to from several threads at once.

def work(n: Int) -> Int
  total = 0
  for k in 1..n
    if k % 3 == 0
      total = total + k
    end
  end

  return total
end

def main() -> Void
  tasks = [Task.spawn(&work, 30000), Task.spawn(&work, 30000), Task.spawn(&work, 30000), Task.spawn(&work, 30000)]
  for task in tasks
    puts(Task.await(task))
  end
end
