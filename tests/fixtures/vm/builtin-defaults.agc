# A builtin with a default parameter (Zlib.crc32 seed = 0): the call site fills the argument that is left out, so
# the call with and without the seed agree, and a given seed is used.
def main() -> Void
  digits = [49, 50, 51, 52, 53, 54, 55, 56, 57]
  puts(Zlib.crc32(digits).unwrap!)
  puts(Zlib.crc32(digits, 0).unwrap!)
  puts((digits |> Zlib.crc32()).unwrap!)
  first = Zlib.crc32(digits.take(3)).unwrap!
  puts(Zlib.crc32(digits.drop(3), first).unwrap!)
  puts(Zlib.crc32(digits, 1).unwrap!)
  puts(Zlib.crc32([]).unwrap!)
end
