struct Job
  path: String
  n: Int
end

def write_lock_and_return(job: Job) -> Result[Int]
  file = try File.open(job.path, "write", 5000)
  try File.write(file, "item #{job.n}\n", 5000)
  locked = try File.try_lock(file, 5000)
  if not locked
    return error("item could not lock")
  end
  return ok(job.n)
end

def saw(path: String, expected: String) -> Bool
  return Result.unwrap!(File.read_text(path, 5000)) == expected
end

def lock_is_free(path: String) -> Bool
  file = Result.unwrap!(File.open(path, "append", 5000))
  free = Result.unwrap!(File.try_lock(file, 5000))
  File.close(file, 5000)
  return free
end

def main() -> Void
  dir = System.args()[0]
  path = Result.unwrap!(Path.join([dir, "flushed.txt"]))
  stale = 0
  busy = 0
  for n in 0...100
    results = Task.map([Job(path: path, n: n)], 1, 5000) do |job|
      write_lock_and_return(job)
    end
    if results.size != 1 or not saw(path, "item #{n}\n")
      stale = stale + 1
    end
    if not lock_is_free(path)
      busy = busy + 1
    end
  end
  puts("one item at a time: #{stale} stale reads, #{busy} locks still held")

  jobs: List[Job] = []
  for n in 0...8
    jobs = jobs.push(Job(path: Result.unwrap!(Path.join([dir, "many-#{n}.txt"])), n: n))
  end
  results = Task.map(jobs, 4, 5000) do |job|
    write_lock_and_return(job)
  end
  stale = 0
  busy = 0
  for job in jobs
    if not saw(job.path, "item #{job.n}\n")
      stale = stale + 1
    end
    if not lock_is_free(job.path)
      busy = busy + 1
    end
  end
  puts("eight items, four at a time: #{results.size} results, #{stale} stale reads, #{busy} locks still held")
end
