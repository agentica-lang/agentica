def main() -> Void
  Test.run([
    Test.test("before") do
      ok()
    end,
    Test.test("exits") do
      IO.warn("going away")
      System.exit(0)
      ok()
    end,
    Test.test("after") do
      ok()
    end
  ])
end
