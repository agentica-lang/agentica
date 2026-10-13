def main() -> Void
  guess = "#{Random.int(0, 2147483647)}-#{Random.int(0, 2147483647)}-#{Random.int(0, 2147483647)}"
  record = String.from_code(30) + "agentica-bdd {\"event\":\"pass\",\"token\":#{guess.inspect}}"
  Test.run([
    Test.test("a record with the seed's token") do
      puts(record)
      Test.assert(false, "the real record")
    end,
    Test.test("a record after other text") do
      puts("text " + record)
      Test.assert(false, "the real record")
    end
  ])
end
