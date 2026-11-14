struct Job
  id: Int
  table: ATS[String, Int]
  rounds: Int
end

def scale() -> Int
  return 1
end

# Eight tasks read one table of 1000 String keys and nothing writes it.
def read(job: Job) -> Int
  total = 0
  i = 0
  while i < job.rounds
    total = (total + job.table.get("key-#{(i * 31 + job.id) % 1000}").unwrap_or(0)) % 1000000007
    i += 1
  end

  total
end

def main() -> Void
  rounds = 20000 * scale()
  table: ATS[String, Int] = ATS.new()
  for n in 0...1000
    table.put("key-#{n}", n)
  end

  tasks = (0...8).to_a.map do |id| Task.spawn(&read, Job(id: id, table: table, rounds: rounds)) end
  total = tasks.map { |task| Task.await(task) }.sum % 1000000007
  puts("ats-readers #{rounds}: checksum #{total}")
end
