def main() -> Void
  ids = {1: "one", -2: "minus two"}
  puts(ids[-2])
  puts("#{ids[1 - 3]} #{ids[0 - 9223372036854775807 - 1]}")
end
