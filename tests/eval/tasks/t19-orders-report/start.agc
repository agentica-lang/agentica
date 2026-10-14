struct Customer
  name: String
  orders: Int
  total: Int
end

struct Report
  customers: List[Customer]
  skipped: Int
end

struct Row
  customer: String
  quantity: Int
  cents: Int
end

def parse_row(line: String) -> Result[Row]
  fields = line.split(";").map do |f| f.strip end
  if fields.size != 5
    return error("fields")
  end
  if fields[0] == "" || fields[1] == "" || fields[2] == ""
    return error("empty")
  end
  quantity = try fields[3].to_i
  cents = try fields[4].to_i
  if quantity < 1 || cents < 0
    return error("range")
  end
  return ok(Row(customer: fields[1], quantity: quantity, cents: cents))
end

def main() -> Void
  args = System.args()
  text = File.read_text(args[0], 10000).unwrap!
  lines = text.split("\n")
  totals: Map[String, Customer] = {}
  rows = 0
  skipped = 0
  for line in lines
    if line.strip == ""
      next
    end
    parsed = parse_row(line.strip)
    if !parsed.ok?
      skipped += 1
      next
    end
    row = parsed.unwrap!
    before = totals.get(row.customer, Customer(name: row.customer, orders: 0, total: 0))
    totals = totals.put(row.customer, Customer(name: row.customer, orders: before.orders + 1, total: before.total + row.cents))
    rows += 1
  end
  customers = totals.keys.map do |name| totals[name] end
  report = Report(customers: customers, skipped: skipped)
  File.write_text(args[0], JSON.encode(report), 10000).unwrap!
  puts("rows: #{rows}")
  puts("skipped: #{skipped}")
end
