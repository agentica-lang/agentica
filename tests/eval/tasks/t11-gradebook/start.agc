struct Totals
  sum: Int
  count: Int
end

def average(totals: Totals) -> Int
  return totals.sum / totals.count
end

def add_score(totals: Totals, score: Int) -> Totals
  return Totals(sum: totals.sum + score, count: totals.count + 1)
end

def main() -> Void
  students: Map[String, Totals] = {}
  everyone = Totals(sum: 0, count: 0)
  while !IO.eof?()
    line = IO.gets!().strip
    if line == ""
      next
    end
    parts = line.split(" ")
    name = parts[0]
    score = parts[2].to_i!
    current = students.get(name, Totals(sum: 0, count: 0))
    students = students.put(name, add_score(current, score))
    everyone = add_score(everyone, score)
  end
  if everyone.count == 0
    puts("no scores")
    return
  end
  for name in students.keys.sort
    puts("#{name}: #{average(students[name])}")
  end
  puts("class: #{average(everyone)}")
end
