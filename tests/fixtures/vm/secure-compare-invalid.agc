def main() -> Void
  puts(HMAC.secure_compare([1], [1]))
  puts(HMAC.secure_compare([1], [256]))
end
