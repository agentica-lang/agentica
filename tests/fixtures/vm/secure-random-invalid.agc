def main() -> Void
  puts(OpenSSL.Random.random_bytes(2).size)
  puts(OpenSSL.Random.hex(-1))
end
