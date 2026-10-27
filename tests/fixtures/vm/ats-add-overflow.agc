def main() -> Void
  t: ATS[String, Int] = ATS.new()
  t.put("max", 9223372036854775807)
  IO.inspect(t.add("max", -7))
  IO.inspect(t.add("max", 7))
  IO.inspect(t.add("max", 1))
end
