def line_total(quantity: Int, price: Float) -> Float
  return quantity * price
end

def main() -> Nil
  total: Int = 0.0
  while not IO.eof?()
    parts = String.split(String.trim(IO.gets()), " ")
    quantity = String.to_int!(parts[1])
    price = String.to_float!(parts[2])
    amount = line_total(quantity, price)
    puts(parts[0] + ": " + amount)
    total = total + amount
  end
  puts("total: " + total)
end
