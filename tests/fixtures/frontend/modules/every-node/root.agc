import Lib from "lib"

struct Local
  item: Lib.Item
  items: List[Lib.Item]
  by_name: Map[String, Lib.Pick]
end

def main() -> Void
  item = Lib.Item(n: 1)
  l = Local(item: item, items: [item], by_name: {"a": Lib.Pick.One(2)})
  f = &Lib.twice
  total = 0
  for x in [1, 2, 3]
    if x > 1 and not (x == 2)
      total += Lib.twice(x)
    elsif x == 1
      next
    else
      break
    end
  end
  while total < 100
    total = total + Lib.twice(total) |> Lib.twice()
  end
  r = [1, 2].map do |v: Int| Lib.twice(v) end
  s = "total #{total} #{Lib.twice(2)} text"
  t = l.items[0].n
  u = l.by_name.get("a")
  case l.by_name["a"]
    Lib.Pick.One(k) -> puts(k)
    Lib.Pick.Zero -> puts(0)
  end
  case total
    1 -> puts("one")
    _ -> puts(-2)
  end
  v = f.call(4)
  w = try u
  x = (1...3)
  y = -total
  puts(s)
end

