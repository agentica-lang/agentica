struct Work
  value: Int
  delay: Int
end

def double(work: Work) -> Int
  Task.sleep(work.delay)
  return work.value * 2
end

def main() -> Void
  first = Task.spawn(&double, Work(value: 21, delay: 10))
  second = Task.spawn(&double, Work(value: 7, delay: 0))
  puts(String.from_int(Task.await(first)))
  puts(String.from_int(Task.await(second)))
end
