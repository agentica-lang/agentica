struct Job
  id: Int
  done: Task[Int]
end

extern module "jobs"
  def finish(job: Job) -> Int
end

def main() -> Void
end
