def main() -> Void
  Test.run([
    Test.test("named") do
      ok()
    end,
    Test.test("") do
      ok()
    end
  ])
end
