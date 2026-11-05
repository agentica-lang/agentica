# A Task.map item that cancels itself through its Task.current handle settles at once as error("task: cancelled"),
# and the others keep their results.
def main() -> Void
  results = Task.map([1, 2, 3, 4], 2, 60000) do |n|
    if n == 2
      Task.cancel(Task.current)
    end

    ok(n * 10)
  end

  puts(results)
end
