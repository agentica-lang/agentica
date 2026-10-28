def main() -> Void
  puts(Base64.strict_encode64([1, 2]))
  puts(Base64.strict_encode64([1, 256, 3]))
end
