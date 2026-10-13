def main() -> Void
  Test.run([
    Test.test("chatty") do
      (1..100000).to_a.each do |i| puts("line #{i} of short test output") end
      ok()
    end,
    Test.test("after") do
      ok()
    end
  ])
end
