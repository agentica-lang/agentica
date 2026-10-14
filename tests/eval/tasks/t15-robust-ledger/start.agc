struct Summary
  balances: Map[String, Int]
  total: Int
end

def apply_line(summary: Summary, line: String) -> Summary
  parts = line.split(" ")
  account = parts[0]
  amount = parts[1].to_i!
  current = summary.balances.get(account, 0)
  return Summary(balances: summary.balances.put(account, current + amount), total: summary.total + amount)
end

def main() -> Void
  balances: Map[String, Int] = {}
  summary = Summary(balances: balances, total: 0)
  while !IO.eof?()
    line = IO.gets!().strip
    if line == "" || line.starts_with?("#")
      next
    end
    summary = apply_line(summary, line)
  end
  for account in summary.balances.keys.sort
    puts("#{account}: #{summary.balances[account]}")
  end
  puts("total: #{summary.total}")
end
