def main() -> Void
  Test.run([
    Test.test("noisy") do
      (1..20).to_a.each do |i| puts("#{i} " + List.repeat("y", 60000).join("")) end
      ok()
    end,
    Test.test("after") do
      ok()
    end
  ])
end
