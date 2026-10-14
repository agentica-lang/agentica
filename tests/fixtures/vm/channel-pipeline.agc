struct Lines
  jobs: Channel[Int]
  results: Channel[Item]
end

struct Item
  index: Int
  square: Int
end

struct Closer
  workers: List[Task[Int]]
  results: Channel[Item]
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
        lines.results.send(Item(index: n, square: n * n), 5000)
        done += 1
      error(_) ->
        if lines.jobs.closed?
          break
        end
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
  results: Channel[Item] = Channel.new(4)
  producer = Task.spawn(&produce, jobs)
  lines = Lines(jobs: jobs, results: results)
  workers = [Task.spawn(&work, lines), Task.spawn(&work, lines), Task.spawn(&work, lines)]
  closer = Task.spawn(&finish, Closer(workers: workers, results: results))
  items: List[Item] = []
  while true
    case results.recv(5000)
      ok(item) -> items = items.append(item)
      error(_) ->
        if results.closed?
          break
        end
    end
  end
  Task.await(producer)
  Task.await(closer)
  ordered = items.sort_by do |item|
    item.index
  end
  puts(ordered.map do |item| item.square end)
  puts(ordered.size)
  handled = workers.map do |worker|
    Task.await(worker)
  end
  puts(handled.reduce(0) do |sum, n| sum + n end)
  puts(results.closed?)
end
