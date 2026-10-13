def main() -> Void
  Test.run([
    Test.test("same") do
      ok()
    end,
    Test.test("same") do
      ok()
    end
  ])
end
