struct Job
  id: Int
  table: ATS[Int, Int]
  rounds: Int
end

def scale() -> Int
  return 1
end

# Eight tasks write one table: each adds to 16 keys that all share and puts and deletes 500 keys of its own.
def write(job: Job) -> Int
  i = 0
  while i < job.rounds
    _ = job.table.add(i % 16, 1)
    own = 1000 * (job.id + 1) + i % 500
    job.table.put(own, i)
    if i % 2 == 0
      job.table.delete(own)
    end

    i += 1
  end

  job.rounds
end

def main() -> Void
  rounds = 20000 * scale()
  table: ATS[Int, Int] = ATS.new()
  tasks = (0...8).to_a.map do |id| Task.spawn(&write, Job(id: id, table: table, rounds: rounds)) end
  done = tasks.map { |task| Task.await(task) }.sum
  shared = (0...16).to_a.map { |key| table.get(key).unwrap_or(0) }.sum
  puts("ats-writers #{rounds}: checksum #{done} #{shared} #{table.size}")
end
