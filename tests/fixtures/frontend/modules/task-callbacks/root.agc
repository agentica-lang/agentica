import "worker" as Worker
def main() -> Void
  task = Task.spawn(&Worker.run, 0)
  IO.inspect(Task.await(task))
end

