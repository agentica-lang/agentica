struct Work
  value: Int
  delay: Int
end

def double(work: Work) -> Int
  Task.sleep(work.delay)
  work.value * 2
end

def main() -> Void
  first = Task.spawn(&double, Work(value: 21, delay: 10))
  second = Task.spawn(&double, Work(value: 7, delay: 0))
  puts(Task.await(first).to_s)
  puts(Task.await(second).to_s)
end
