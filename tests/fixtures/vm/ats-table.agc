struct Holder
  name: String
  table: ATS[Int, List[String]]
end

def main() -> Void
  t: ATS[String, Int] = ATS.new()
  IO.inspect(t.size)
  t.put("b", 2)
  t.put("a", 1)
  t.put("c", 3)
  t.put("b", 20)
  IO.inspect(t.to_map)
  t.delete("b")
  t.delete("missing")
  t.put("b", 200)
  IO.inspect(t.keys)
  IO.inspect(t.put_new("a", 9))
  IO.inspect(t.put_new("d", 4))
  IO.inspect(t.get("a"))
  IO.inspect(t.get("zz"))
  IO.inspect([t.has_key?("d"), t.has_key?("zz")])
  IO.inspect(t.add("a", 41))
  IO.inspect(t.add("new", -5))
  IO.inspect(t.to_map)
  IO.inspect(t.size)
  numbers: ATS[Int, List[String]] = ATS.new()
  numbers.put(30, ["x"])
  numbers.put(-1, [])
  numbers.put(7, ["y", "z"])
  IO.inspect(numbers.keys)
  holder = Holder(name: "h", table: numbers)
  same = holder.table
  same.delete(30)
  IO.inspect(numbers.to_map)
  IO.inspect(holder)
end
