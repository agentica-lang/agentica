struct Dept
  rows: Int
  total: Int
  top_name: String
  top_salary: Int
end

struct Row
  name: String
  dept: String
  salary: Int
end

def add_row(dept: Dept, name: String, salary: Int) -> Dept
  if dept.rows == 0 || salary > dept.top_salary
    return Dept(rows: dept.rows + 1, total: dept.total + salary, top_name: name, top_salary: salary)
  end
  return Dept(rows: dept.rows + 1, total: dept.total + salary, top_name: dept.top_name, top_salary: dept.top_salary)
end

def parse_row(line: String) -> Result[Row]
  fields = line.split(",")
  if fields.size != 3
    return error("expected 3 fields, got #{fields.size}")
  end
  name = fields[0].strip
  dept = fields[1].strip
  text = fields[2].strip
  if name == ""
    return error("empty name")
  end
  if dept == ""
    return error("empty department")
  end
  salary = text.to_i
  if !salary.ok?
    return error("bad salary \"#{text}\"")
  end
  if salary.unwrap! < 0
    return error("negative salary")
  end
  return ok(Row(name: name, dept: dept, salary: salary.unwrap!))
end

def main() -> Void
  depts: Map[String, Dept] = {}
  empty = Dept(rows: 0, total: 0, top_name: "", top_salary: 0)
  header = true
  number = 0
  rejected = 0
  while !IO.eof?()
    line = IO.gets!().strip
    number += 1
    if header
      header = false
      next
    end
    if line == ""
      next
    end
    parsed = parse_row(line)
    if parsed.ok?
      row = parsed.unwrap!
      depts = depts.put(row.dept, add_row(depts.get(row.dept, empty), row.name, row.salary))
    else
      puts("line #{number}: #{parsed.message}")
      rejected += 1
    end
  end
  if depts.size == 0
    puts("no rows")
  end
  for dept in depts.keys.sort
    d = depts[dept]
    puts("#{dept}: #{d.rows} rows, total #{d.total}, average #{d.total / d.rows}, top #{d.top_name}")
  end
  puts("rejected: #{rejected}")
end
