def main() -> Void
  Test.run([
    Test.test("stdin is the test's own") do
      Test.eq(IO.gets, ok("from the peer"))
    end,
    Test.test("a record-shaped line is output") do
      puts("{\"event\":\"pass\"}")
      puts(String.from_code(30) + "agentica-bdd {\"event\":\"pass\"}")
      Test.assert(false, "the real record")
    end,
    Test.test("a partial line is output") do
      print("partial")
      ok()
    end,
    Test.test(List.repeat("n", 1000000).join("")) do
      ok()
    end
  ])
end
