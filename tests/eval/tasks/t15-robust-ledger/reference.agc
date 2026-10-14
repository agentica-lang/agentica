struct Summary
  balances: Map[String, Int]
  total: Int
  rejected: Int
end

def valid_account(name: String) -> Bool
  if name.length > 16
    return false
  end
  for i in 0...name.length
    code = String.code(name.at(i))
    letter = code >= 97 && code <= 122
    digit = code >= 48 && code <= 57
    if i == 0 && !letter
      return false
    end
    if !letter && !digit && code != 95
      return false
    end
  end
  return true
end

def apply_line(summary: Summary, line: String) -> Result[Summary]
  parts = line.split(" ")
  if parts.size != 2
    return error("expected 2 fields")
  end
  account = parts[0]
  if !valid_account(account)
    return error("bad account")
  end
  parsed = parts[1].to_i
  if !parsed.ok?
    return error("bad amount")
  end
  amount = parsed.unwrap!
  if amount > 1000000 || amount < -1000000
    return error("amount out of range")
  end
  current = summary.balances.get(account, 0)
  return ok(Summary(balances: summary.balances.put(account, current + amount), total: summary.total + amount, rejected: summary.rejected))
end

def main() -> Void
  balances: Map[String, Int] = {}
  summary = Summary(balances: balances, total: 0, rejected: 0)
  number = 0
  while !IO.eof?()
    line = IO.gets!().strip
    number += 1
    if line == "" || line.starts_with?("#")
      next
    end
    result = apply_line(summary, line)
    if result.ok?
      summary = result.unwrap!
    else
      puts("line #{number}: #{result.message}")
      summary = Summary(balances: summary.balances, total: summary.total, rejected: summary.rejected + 1)
    end
  end
  for account in summary.balances.keys.sort
    puts("#{account}: #{summary.balances[account]}")
  end
  puts("total: #{summary.total}")
  puts("rejected: #{summary.rejected}")
end
