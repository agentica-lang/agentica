def main() -> Void
  Test.run([
    Test.test("first draw") do
      Test.eq(Random.int(0, 1000000000), -1)
    end,
    Test.test("second draw") do
      Test.eq(Random.int(0, 1000000000), -1)
    end
  ])
end
