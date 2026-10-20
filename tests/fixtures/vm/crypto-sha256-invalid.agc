def main() -> Void
  puts(Crypto.sha256([1, 2]).size)
  puts(Crypto.sha256([1, 256, 3]))
end
