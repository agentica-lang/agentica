def main() -> Void
  Test.run([
    Test.test("reads its standard input") do
      line = IO.gets
      Test.assert(not line.ok?, "the test's stdin is its own and ends at once")
    end,
    Test.test("prints a line shaped like a record") do
      puts("{\"event\":\"pass\"}")
      IO.print("no newline")
      Test.assert(false, "the real record")
    end,
    Test.test("prints without a newline") do
      IO.print("tail")
      ok()
    end
  ])
end
