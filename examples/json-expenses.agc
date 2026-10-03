struct ExpenseReport
  totals: Map[String, Int]
end

def expense_totals(text: String) -> Result[Map[String, Int]]
  root = try JSON.parse(text)
  entries = try JSON.list(root)
  totals: Map[String, Int] = {}
  for entry in entries
    category = try JSON.string(try JSON.get(entry, "category"))
    amount = try JSON.int(try JSON.get(entry, "amount"))
    previous = 0
    if Map.has_key?(totals, category)
      previous = totals[category]
    end
    totals = Map.put(totals, category, previous + amount)
  end
  return ok(totals)
end

def main() -> Nil
  report = expense_totals(IO.read())
  if Result.ok?(report)
    puts(JSON.encode(ExpenseReport(totals: Result.unwrap!(report))))
  else
    puts(JSON.encode({"error": "invalid expense"}))
  end
end
