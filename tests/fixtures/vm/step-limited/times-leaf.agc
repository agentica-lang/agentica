def nothing(i: Int) -> Void
end

def main() -> Void
  9223372036854775807.times(&nothing)
  puts("done")
end
