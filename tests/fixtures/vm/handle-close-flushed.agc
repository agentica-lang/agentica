struct Job
  path: String
  n: Int
  files: Channel[FileHandle]
end

def write_and_return(job: Job) -> FileHandle
  file = Result.unwrap!(File.open(job.path, "write", 5000))
  Result.unwrap!(File.write(file, "returned #{job.n}\n", 5000))
  return file
end

def write_and_crash(job: Job) -> Result[Int]
  file = Result.unwrap!(File.open(job.path, "write", 5000))
  Result.unwrap!(File.write(file, "crashed #{job.n}\n", 5000))
  zero = 0
  return ok(job.n / zero)
end

def write_and_send(job: Job) -> Void
  file = Result.unwrap!(File.open(job.path, "write", 5000))
  Result.unwrap!(File.write(file, "sent #{job.n}\n", 5000))
  job.files.send(file, 5000)
end

def saw(path: String, expected: String) -> Bool
  return Result.unwrap!(File.read_text(path, 5000)) == expected
end

def main() -> Void
  path = Result.unwrap!(Path.join([System.args()[0], "flushed.txt"]))
  files: Channel[FileHandle] = Channel.new(1)

  stale = 0
  for n in 0...200
    file = Task.await(Task.spawn(&write_and_return, Job(path: path, n: n, files: files)))
    if not saw(path, "returned #{n}\n")
      stale = stale + 1
    end
  end
  puts("returned and awaited: #{stale} stale reads")

  stale = 0
  for n in 0...4
    outcome = Task.await(Task.spawn(&write_and_crash, Job(path: path, n: n, files: files)))
    if not saw(path, "crashed #{n}\n")
      stale = stale + 1
    end
  end
  puts("crashed and awaited: #{stale} stale reads")

  stale = 0
  failed = 0
  for n in 0...100
    Task.spawn(&write_and_send, Job(path: path, n: n, files: files))
    file = Result.unwrap!(files.recv(5000))
    if not File.close(file, 5000).ok?
      failed = failed + 1
    end
    if not saw(path, "sent #{n}\n")
      stale = stale + 1
    end
  end
  puts("sent and closed by another task: #{failed} failed closes, #{stale} stale reads")
end
