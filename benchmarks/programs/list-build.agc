def scale() -> Int
  return 1
end

def main() -> Void
  n = 20000 * scale()
  xs: List[Int] = []
  i = 0
  while i < n
    xs = xs.push((i * 7919) % 10007)
    i += 1
  end
  j = 0
  while j < n
    xs = xs.set((j * 7919) % n, j)
    j += 1
  end
  total = 0
  for x in xs
    total = (total * 31 + x) % 1000000007
  end
  puts("list-build #{n}: checksum #{total}")
end
