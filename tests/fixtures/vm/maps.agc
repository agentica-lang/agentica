struct Stock
  name: String
  counts: Map[String, Int]
end

enum Slot
  Filled(Map[Int, String])
  Blank
end

def lookup(table: Map[String, Int], key: String) -> Int
  return table[key]
end

def scores(bonus: Int) -> Map[String, Int]
  return {"low": 1 + bonus, "high": 10 * bonus}
end

def first_label(groups: List[Map[Int, String]]) -> String
  return groups[0][1]
end

def describe(slot: Slot) -> String
  case slot
    Slot.Filled(m) -> return "filled #{m}"
    Slot.Blank -> return "blank"
  end
end

def pick(flag: Bool) -> Result[Map[String, Float]]
  if flag
    return ok({"pi": 3.14, "neg": -0.0})
  end
  return error("no \"map\"")
end

def main() -> Void
  ages = {"Ana": 31, "Bo": 4, "Cy": 27}
  puts(ages)
  puts(ages["Bo"])
  puts(lookup(ages, "Cy") + ages["Ana"])
  repeated = {"b": 1, "a": 2, "b": 3, "c": 4, "a": 5}
  puts(repeated)
  ints = {3: "three", -1: "minus one", 9223372036854775807: "max", 0: ""}
  puts(ints)
  puts(ints[-1])
  puts(ints[9223372036854775807].inspect)
  empty_strings: Map[String, Int] = {}
  empty_ints: Map[Int, List[String]] = {}
  puts(empty_strings)
  print(empty_ints)
  print("\n")
  IO.warn(ages)
  odd = {"tab\there": "q\"uote", "λ 😀": "back\\slash", "": "empty key", "nl\n": "\r"}
  puts(odd)
  puts(odd["λ 😀"])
  puts(odd[""])
  puts("ages #{ages}, empty #{empty_strings}, odd #{odd}")
  puts(ages.to_s)
  puts(odd.inspect)
  values = {"f": 1.5, "nan": 0.0 / 1.0, "big": 100000000000000000000.0 * 10.0}
  puts(values)
  flags = {1: true, 2: false, 3: nil == nil}
  puts(flags)
  nested = {"outer": {"inner": [1, 2, 3]}, "other": {}}
  puts(nested)
  puts(nested["outer"]["inner"][2])
  groups = [{1: "one", 2: "two"}, {}, {1: "uno"}]
  puts(groups)
  puts(first_label(groups))
  lists = {"xs": [[1], []], "ys": []}
  puts(lists)
  stock = Stock(name: "shop", counts: {"apple": 3, "pear": 0})
  puts(stock)
  puts(stock.counts["apple"])
  puts(describe(Slot.Filled({7: "seven"})))
  puts(describe(Slot.Blank))
  puts([Slot.Filled({}), Slot.Blank])
  puts(pick(true))
  puts(pick(false))
  case pick(true)
    ok(m) -> puts(m["pi"])
    error(message) -> puts(message)
  end
  puts(scores(2))
  puts(scores(3)["high"])
  results = {"good": ok(1), "bad": error("nope")}
  puts(results)
  maps_of_maps = {1: {2: {3: {4: "deep"}}}}
  puts(maps_of_maps)
  puts(maps_of_maps[1][2][3][4])
  rebound = ages
  ages = {"Zed": 0}
  puts(rebound)
  puts(ages)
end
