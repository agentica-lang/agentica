def work(n: Int) -> Int
  total = 0
  i = 0
  while i < n
    total = total + i % 7
    i = i + 1
    if i % 500 == 0
      Task.sleep(0)
    end
  end
  return total
end

def main() -> Void
  tasks = (1..6).to_a.map do |k|
    Task.spawn(&work, k * 3000)
  end
  sums = tasks.map do |t|
    Task.await(t)
  end
  IO.inspect(sums)
end
