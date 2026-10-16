def main() -> Void
  x = 0
  IO.warn("before #{x}")
  puts(<<~TEXT)
    first line
    second #{10 / x} never
  TEXT
end
