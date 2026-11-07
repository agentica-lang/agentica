struct Job
  id: Int
  done: Task[Int]
end

extern module "jobs"
  resource Queue
  def queue() -> Queue
  def finish(job: Job) -> Int
end

def main() -> Void
end
