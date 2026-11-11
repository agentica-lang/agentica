# Task.spawn_owning hands over every handle in its argument, and closes it when the task ends. An address is data, not
# a handle: a task can own its own channel and still send to a shared one through the shared one's address.
struct Link
  jobs: Channel[Int]
  results: Address[Int]
end

struct Both
  jobs: Channel[Int]
  results: Channel[Int]
end

def report(label: String, r: Result[Int]) -> Void
  case r
    ok(n) -> puts("#{label}: ok #{n}")
    error(e) -> puts("#{label}: #{e}")
  end
end

def serve(link: Link) -> Result[Int]
  n = try link.jobs.recv(1000)
  try link.results.send(n * 10, 1000)
  ok(n)
end

def serve_both(both: Both) -> Result[Int]
  n = try both.jobs.recv(1000)
  try both.results.send(n * 10, 1000)
  ok(n)
end

def main() -> Void
  results: Channel[Int] = Channel.new(4)
  for n in [1, 2]
    jobs: Channel[Int] = Channel.new(1)
    _ = jobs.send(n, 100)
    report("worker", Task.await(Task.spawn_owning(&serve, Link(jobs: jobs, results: results.address))))
    puts("jobs closed? #{jobs.closed?}, results closed? #{results.closed?}")
  end
  IO.inspect(results.recv(100))
  IO.inspect(results.recv(100))

  jobs: Channel[Int] = Channel.new(1)
  _ = jobs.send(3, 100)
  report("owning both", Task.await(Task.spawn_owning(&serve_both, Both(jobs: jobs, results: results))))
  puts("jobs closed? #{jobs.closed?}, results closed? #{results.closed?}")
  IO.inspect(results.recv(100))
  IO.inspect(results.recv(100))
end
