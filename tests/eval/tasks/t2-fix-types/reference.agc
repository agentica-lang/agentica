def line_total(quantity: Float, price: Float) -> Float
  return quantity * price
end

def main() -> Void
  total = 0.0
  while not IO.eof?()
    parts = String.split(IO.gets!().strip, " ")
    quantity = parts[1].to_f!
    price = parts[2].to_f!
    amount = line_total(quantity, price)
    puts(parts[0] + ": " + amount.to_s)
    total = total + amount
  end
  puts("total: " + total.to_s)
end
