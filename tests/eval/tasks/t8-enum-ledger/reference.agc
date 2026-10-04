enum Command[T]
  Credit(T)
  Debit(T)
  Show
  Reset
end

def parse_command(line: String) -> Result[Command[Int]]
  words = String.split(String.trim(line), " ")
  if List.size(words) == 1
    word = List.at(words, 0)
    if word == "show"
      return ok(Command.Show())
    elsif word == "reset"
      return ok(Command.Reset())
    end
  end
  if List.size(words) == 2
    operation = List.at(words, 0)
    amount_result = String.to_int(List.at(words, 1))
    case amount_result do
      Result.Ok(amount) ->
        if amount < 0 or amount > 1000000
          return error("invalid amount")
        end
        case operation do
          "credit" ->
            return ok(Command.Credit(amount))
          "debit" ->
            return ok(Command.Debit(amount))
          _ ->
            return error("unknown command")
        end
      Result.Err(_) ->
        return error("invalid amount")
    end
  end
  return error("invalid command")
end

def main() -> Void
  balance = 0
  while not IO.eof?()
    command_result = parse_command(IO.gets!())
    case command_result do
      Result.Ok(command) ->
        case command do
          Command.Credit(amount) ->
            balance = balance + amount
            puts("balance: " + String.from_int(balance))
          Command.Debit(amount) ->
            if amount > balance
              puts("error")
            else
              balance = balance - amount
              puts("balance: " + String.from_int(balance))
            end
          Command.Show ->
            puts("balance: " + String.from_int(balance))
          Command.Reset ->
            balance = 0
            puts("balance: 0")
        end
      Result.Err(_) ->
        puts("error")
    end
  end
  puts("final: " + String.from_int(balance))
end
