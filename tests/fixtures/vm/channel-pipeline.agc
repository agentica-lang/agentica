struct Lines
  jobs: Channel[Int]
  results: Channel[Int]
end

struct Closer
  workers: List[Task[Int]]
  results: Channel[Int]
end

def produce(jobs: Channel[Int]) -> Void
  for i in 1..30
    jobs.send(i, 5000)
  end
  jobs.close
end

def work(lines: Lines) -> Int
  done = 0
  while true
    case lines.jobs.recv(5000)
      ok(n) ->
        lines.results.send(n * n, 5000)
        done += 1
      error(_) -> break
    end
  end
  return done
end

def finish(closer: Closer) -> Void
  closer.workers.each do |worker|
    Task.await(worker)
  end
  closer.results.close
end

def main() -> Void
  jobs: Channel[Int] = Channel.new(4)
  results: Channel[Int] = Channel.new(4)
  producer = Task.spawn(&produce, jobs)
  lines = Lines(jobs: jobs, results: results)
  workers = [Task.spawn(&work, lines), Task.spawn(&work, lines), Task.spawn(&work, lines)]
  closer = Task.spawn(&finish, Closer(workers: workers, results: results))
  squares: List[Int] = []
  while true
    case results.recv(5000)
      ok(n) -> squares = squares.append(n)
      error(e) ->
        puts(e)
        break
    end
  end
  Task.await(producer)
  Task.await(closer)
  puts(squares.sort)
  puts(squares.size)
  handled = workers.map do |worker|
    Task.await(worker)
  end
  puts(handled.reduce(0) do |sum, n| sum + n end)
  puts(results.closed?)
end
