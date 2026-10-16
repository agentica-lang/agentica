struct Job
  path: String
  n: Int
end

# Leaves the file open: its write sits in the handle's buffer until the task's close job flushes it.
def write_and_return(job: Job) -> Result[Int]
  file = try File.open(job.path, "write", 5000)
  try File.write(file, "item #{job.n}\n", 5000)
  return ok(job.n)
end

def saw(path: String, expected: String) -> Bool
  return Result.unwrap!(File.read_text(path, 5000)) == expected
end

# Task.map settles an item only after the close of its files has finished, as Task.await does, so the read right
# after the call always sees what the item wrote. The close runs on a pool thread, so a map that did not wait lost
# this race now and then; the many rounds make that likely, and a correct map never loses it.
def main() -> Void
  dir = System.args()[0]
  path = Result.unwrap!(Path.join([dir, "flushed.txt"]))
  stale = 0
  for n in 0...1000
    results = Task.map([Job(path: path, n: n)], 1, 5000) do |job|
      write_and_return(job)
    end
    if results.size != 1 or not saw(path, "item #{n}\n")
      stale = stale + 1
    end
  end
  puts("#{stale} stale reads in 1000 rounds")
end
