def main() -> Void
  IO.warn("bad config")
  System.exit(3)
  Test.run([Test.test("never listed") do ok() end])
end
