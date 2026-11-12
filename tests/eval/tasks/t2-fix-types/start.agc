def line_total(quantity: Int, price: Float) -> Float
  return quantity * price
end

def main() -> Void
  total: Int = 0.0
  while not IO.eof?()
    parts = String.split(IO.gets!().strip, " ")
    quantity = parts[1].to_i!
    price = parts[2].to_f!
    amount = line_total(quantity, price)
    puts(parts[0] + ": " + amount)
    total = total + amount
  end
  puts("total: " + total)
end
