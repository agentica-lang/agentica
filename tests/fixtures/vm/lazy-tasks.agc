# One Lazy shared by several tasks: a recipe is immutable, each terminal has its own run, and the callbacks run on the
# task that called the terminal. tests/test_vm_multicore.py runs this fixture on four schedulers too.
def main() -> Void
  primes = Lazy.produce(2) do |n| n + 1 end.filter do |n|
    (2...n).to_a.all? do |d| n % d != 0 end
  end
  results = Task.map([5, 10, 20, 40], 4, 60000) do |count|
    primes.first(count)
  end
  for result in results
    found = result.unwrap!
    puts("#{found.size} primes, the last #{found[found.size - 1]}")
  end
end
