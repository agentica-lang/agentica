def line_total(quantity: Float, price: Float) -> Float
  return quantity * price
end

def main() -> Nil
  total = 0.0
  while not IO.eof?()
    parts = String.split(String.trim(IO.gets()), " ")
    quantity = String.to_float!(parts[1])
    price = String.to_float!(parts[2])
    amount = line_total(quantity, price)
    puts(parts[0] + ": " + String.from_float(amount))
    total = total + amount
  end
  puts("total: " + String.from_float(total))
end
