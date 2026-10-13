def main() -> Void
  Test.run([
    Test.test("first") do
      puts("bodies do not run in list mode")
      ok()
    end,
    Test.test("second \"quoted\"") do
      Test.assert(false, "not run")
    end
  ])
end
