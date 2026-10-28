def main() -> Void
  puts(SecureRandom.random_bytes(2).size)
  puts(SecureRandom.hex(-1))
end
