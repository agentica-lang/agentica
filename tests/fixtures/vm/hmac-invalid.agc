def main() -> Void
  puts(HMAC.sha256([1], [2]).size)
  puts(HMAC.sha256([1], [2, 256]))
end
