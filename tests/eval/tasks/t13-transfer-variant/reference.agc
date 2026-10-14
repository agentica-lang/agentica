enum Txn
  Deposit(Int)
  Withdraw(Int)
  Fee(Int, String)
  Transfer(Int, String)
end

struct Stats
  inflow: Int
  outflow: Int
  fees: Int
  transferred: Int
  rejected: Int
end

def parse_amount(text: String) -> Result[Int]
  n = try text.to_i
  if n <= 0
    return error("amount must be positive")
  end
  return ok(n)
end

def parse_txn(line: String) -> Result[Txn]
  parts = line.split(" ").filter do |w| w != "" end
  if parts.size == 2 && parts[0] == "deposit"
    return ok(Txn.Deposit(try parse_amount(parts[1])))
  elsif parts.size == 2 && parts[0] == "withdraw"
    return ok(Txn.Withdraw(try parse_amount(parts[1])))
  elsif parts.size == 3 && parts[0] == "fee"
    return ok(Txn.Fee(try parse_amount(parts[1]), parts[2]))
  elsif parts.size == 3 && parts[0] == "transfer"
    return ok(Txn.Transfer(try parse_amount(parts[1]), parts[2]))
  end
  return error("unknown command")
end

def describe(txn: Txn) -> String
  case txn
    Txn.Deposit(amount) -> return "deposit #{amount}"
    Txn.Withdraw(amount) -> return "withdraw #{amount}"
    Txn.Fee(amount, label) -> return "fee #{amount} (#{label})"
    Txn.Transfer(amount, to) -> return "transfer #{amount} to #{to}"
  end
end

def category(txn: Txn) -> String
  case txn
    Txn.Deposit(_) -> return "inflow"
    Txn.Withdraw(_) -> return "outflow"
    Txn.Fee(_, _) -> return "fee"
    Txn.Transfer(_, _) -> return "transfer"
  end
end

def apply_txn(balance: Int, txn: Txn) -> Result[Int]
  case txn
    Txn.Deposit(amount) ->
      return ok(balance + amount)
    Txn.Withdraw(amount) ->
      if amount > balance
        return error("insufficient funds")
      end
      return ok(balance - amount)
    Txn.Fee(amount, _) ->
      if amount > balance
        return error("insufficient funds")
      end
      return ok(balance - amount)
    Txn.Transfer(amount, _) ->
      if amount > balance
        return error("insufficient funds")
      end
      return ok(balance - amount)
  end
end

def tally(stats: Stats, txn: Txn) -> Stats
  case txn
    Txn.Deposit(amount) ->
      return Stats(inflow: stats.inflow + amount, outflow: stats.outflow, fees: stats.fees, transferred: stats.transferred, rejected: stats.rejected)
    Txn.Withdraw(amount) ->
      return Stats(inflow: stats.inflow, outflow: stats.outflow + amount, fees: stats.fees, transferred: stats.transferred, rejected: stats.rejected)
    Txn.Fee(amount, _) ->
      return Stats(inflow: stats.inflow, outflow: stats.outflow, fees: stats.fees + amount, transferred: stats.transferred, rejected: stats.rejected)
    Txn.Transfer(amount, _) ->
      return Stats(inflow: stats.inflow, outflow: stats.outflow, fees: stats.fees, transferred: stats.transferred + amount, rejected: stats.rejected)
  end
end

def main() -> Void
  balance = 0
  stats = Stats(inflow: 0, outflow: 0, fees: 0, transferred: 0, rejected: 0)
  while !IO.eof?()
    line = IO.gets!().strip
    if line == ""
      next
    end
    parsed = parse_txn(line)
    if !parsed.ok?
      puts("invalid: #{line}")
      next
    end
    txn = parsed.unwrap!
    applied = apply_txn(balance, txn)
    if applied.ok?
      balance = applied.unwrap!
      stats = tally(stats, txn)
      puts("#{category(txn)}: #{describe(txn)} -> #{balance}")
    else
      stats = Stats(inflow: stats.inflow, outflow: stats.outflow, fees: stats.fees, transferred: stats.transferred, rejected: stats.rejected + 1)
      puts("rejected: #{describe(txn)} (#{applied.message})")
    end
  end
  puts("balance: #{balance}")
  puts("inflow: #{stats.inflow}")
  puts("outflow: #{stats.outflow}")
  puts("fees: #{stats.fees}")
  puts("transferred: #{stats.transferred}")
  puts("rejected: #{stats.rejected}")
end
