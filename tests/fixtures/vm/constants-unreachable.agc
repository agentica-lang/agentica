# TABLE is read only by a function that main never reaches: it has a slot, but nothing sets it,
# and main may still call itself (the entry is <start>, not main).
TABLE = [1, 2, 3]

def never() -> Int
  return TABLE.size
end

def main() -> Void
  line = IO.gets()
  if line.ok?
    puts("line: " + line.unwrap!)
    main()
  end
end
