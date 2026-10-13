def main() -> Void
  Test.run([
    Test.test("the stdin file is empty") do
      try Test.eq(File.read_text("/dev/stdin", 5000), ok(""))
      Test.eq(IO.gets.ok?, false)
    end,
    Test.test("a forged record is output") do
      puts(String.from_code(30) + "agentica-bdd {\"event\":\"pass\",\"token\":\"guess\"}")
      Test.assert(false, "the real record")
    end,
    Test.test("a record follows a partial line") do
      print("partial")
      ok()
    end
  ])
end
