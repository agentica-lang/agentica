struct Entry
  student: String
  subject: String
  score: Int
end

struct Totals
  sum: Int
  weight: Int
end

def average(totals: Totals) -> Int
  return totals.sum / totals.weight
end

def add_score(totals: Totals, score: Int, weight: Int) -> Totals
  return Totals(sum: totals.sum + score * weight, weight: totals.weight + weight)
end

def letter(avg: Int) -> String
  if avg >= 90
    return "A"
  elsif avg >= 80
    return "B"
  elsif avg >= 70
    return "C"
  elsif avg >= 60
    return "D"
  end
  return "F"
end

def main() -> Void
  entries: List[Entry] = []
  weights: Map[String, Int] = {}
  while !IO.eof?()
    line = IO.gets!().strip
    if line == ""
      next
    end
    parts = line.split(" ")
    if parts[0] == "weight"
      weights = weights.put(parts[1], parts[2].to_i!)
    else
      entries = entries.push(Entry(student: parts[0], subject: parts[1], score: parts[2].to_i!))
    end
  end
  if entries.size == 0
    puts("no scores")
    return
  end
  students: Map[String, Totals] = {}
  everyone = Totals(sum: 0, weight: 0)
  for entry in entries
    w = weights.get(entry.subject, 1)
    current = students.get(entry.student, Totals(sum: 0, weight: 0))
    students = students.put(entry.student, add_score(current, entry.score, w))
    everyone = add_score(everyone, entry.score, w)
  end
  ranked = students.keys.sort.sort_by do |name| 0 - average(students[name]) end
  rank = 1
  for name in ranked
    avg = average(students[name])
    puts("#{rank}. #{name}: #{avg} #{letter(avg)}")
    rank += 1
  end
  puts("class: #{average(everyone)}")
end
