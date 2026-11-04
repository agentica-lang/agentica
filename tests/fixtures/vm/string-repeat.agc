RULE = "=" * 8

# String * Int repeats the String, as Ruby's String#*; a negative count halts at the count.
def main() -> Void
  puts("ab" * 3)
  puts("é€" * 2)
  puts(("" * 9223372036854775807).length)
  puts(("x" * 0).empty?)
  line = "-"
  line *= 4
  puts(line + RULE)
  puts(("abc" * 1000).length)
  count = 2 - 3
  puts("never" * count)
end
