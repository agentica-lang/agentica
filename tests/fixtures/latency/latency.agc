def spin(n: Int) -> Int
  x = 0
  while true
    x = (x + n) % 1000
  end
  return x
end

def sorter(n: Int) -> Int
  xs = (0...n).to_a.reverse
  while true
    ys = xs.sort
  end
  return 0
end

def concat(n: Int) -> Int
  big = String.join(List.repeat("x", n), "")
  small = "a"
  while true
    t = small + big
  end
  return 0
end

def sleeper(rounds: Int) -> Int
  worst = 0
  i = 0
  while i < rounds
    before = Time.monotonic_ms()
    Task.sleep(10)
    late = Time.monotonic_ms() - before - 10
    if late > worst
      worst = late
    end
    if worst > 1000
      return worst
    end
    i = i + 1
  end
  return worst
end

def echo(rounds: Int) -> Int
  i = 0
  while i < rounds
    puts("ready")
    IO.flush()
    line = IO.gets!()
    puts("echo #{line}")
    IO.flush()
    i = i + 1
  end
  return 0
end

def main() -> Void
  a = Task.spawn(&spin, 7)
  b = Task.spawn(&sorter, 100000)
  c = Task.spawn(&concat, 1048576)
  Task.sleep(50)
  if System.args()[0] == "sleep"
    puts("worst #{Task.await(Task.spawn(&sleeper, 30))}")
  else
    Task.await(Task.spawn(&echo, 20))
  end
end
