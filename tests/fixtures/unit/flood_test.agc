def warn() -> Result[Void]
  IO.warn(List.repeat("x", 100000).join(""))
  return ok()
end

def main() -> Void
  Test.run((1..11).to_a.map do |i| Test.test("t#{i}") do warn() end end)
end
