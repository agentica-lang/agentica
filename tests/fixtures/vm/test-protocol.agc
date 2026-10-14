def main() -> Void
  puts("main reads: #{IO.gets.unwrap_or("nothing")}")
  Test.run([
    Test.test("stdin goes on in a test") do
      Test.eq(IO.gets, ok("second line"))
    end,
    Test.test("a line shaped like a record is output") do
      puts("{\"event\":\"pass\"}")
      puts(String.from_code(30) + "agentica-bdd {\"event\":\"pass\"}")
      Test.assert(false, "the real record")
    end,
    Test.test("a partial line stays output") do
      print("partial")
      ok()
    end
  ])
end
