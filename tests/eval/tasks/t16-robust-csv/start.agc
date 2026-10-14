struct Dept
  rows: Int
  total: Int
  top_name: String
  top_salary: Int
end

def add_row(dept: Dept, name: String, salary: Int) -> Dept
  if dept.rows == 0 || salary > dept.top_salary
    return Dept(rows: dept.rows + 1, total: dept.total + salary, top_name: name, top_salary: salary)
  end
  return Dept(rows: dept.rows + 1, total: dept.total + salary, top_name: dept.top_name, top_salary: dept.top_salary)
end

def main() -> Void
  depts: Map[String, Dept] = {}
  empty = Dept(rows: 0, total: 0, top_name: "", top_salary: 0)
  header = true
  while !IO.eof?()
    line = IO.gets!().strip
    if header
      header = false
      next
    end
    if line == ""
      next
    end
    fields = line.split(",")
    name = fields[0].strip
    dept = fields[1].strip
    salary = fields[2].strip.to_i!
    depts = depts.put(dept, add_row(depts.get(dept, empty), name, salary))
  end
  if depts.size == 0
    puts("no rows")
    return
  end
  for dept in depts.keys.sort
    d = depts[dept]
    puts("#{dept}: #{d.rows} rows, total #{d.total}, average #{d.total / d.rows}, top #{d.top_name}")
  end
end
