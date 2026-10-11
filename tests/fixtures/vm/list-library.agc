struct Point
  x: Int
  y: Int
end

def main() -> Void
  xs = [3, 1, 2]
  puts(List.size(xs))
  puts(xs.size)
  puts(xs.length)
  empty: List[Int] = []
  puts(empty.size)
  ys = List.append(xs, 9)
  puts(ys)
  puts(xs)
  puts(xs.push(4).push(5))
  puts(empty.append(1))
  puts(List.at(xs, 0) + xs.at(2))
  puts(List.set(xs, 1, 100))
  puts(xs.set(2, -2))
  puts(xs)
  puts(List.repeat("ab", 3))
  puts(List.repeat([1], 0))
  puts(List.repeat(Point(x: 1, y: 2), 2))
  puts(List.concat(xs, [7, 8]))
  puts(xs.concat(empty))
  puts(empty.concat(empty))
  puts(List.take(xs, 2))
  puts(xs.take(0))
  puts(xs.take(9223372036854775807))
  puts(List.drop(xs, 1))
  puts(xs.drop(3))
  puts(xs.drop(9223372036854775807))
  puts(List.reverse(xs))
  puts(empty.reverse)
  puts([[1], [2, 3]].reverse)
  puts(List.sort(xs))
  puts([5, -1, 9223372036854775807, -9223372036854775807 - 1, 0, 5].sort)
  inf = 100000000000000000000.0
  while inf < inf * inf
    inf = inf * inf
  end
  nan = inf - inf
  puts([2.5, nan, -0.0, 0.0, -1.0, nan, inf, -inf, 0.0, -0.0].sort)
  puts(["pear", "", "apple", "Zed", "λ", "app", "😀", "é"].sort)
  puts(empty.sort)
  puts(["one"].sort)
  words = ["b", "a"]
  sorted = words.sort
  puts(words)
  puts(sorted)
  puts(List.size(List.repeat(0, 1048576)))
  big = List.repeat(1, 1000)
  puts(big.drop(998))
  puts(big.take(1000).size)
  puts(xs.append(4).sort.reverse.take(2).drop(1).at(0))
end
