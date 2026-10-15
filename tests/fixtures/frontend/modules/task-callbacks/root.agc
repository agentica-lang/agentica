import Worker from "worker"
def main() -> Void
  task = Task.spawn(&Worker.run, 0)
  IO.inspect(Task.await(task))
end

