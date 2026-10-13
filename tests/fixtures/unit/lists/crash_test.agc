def main() -> Void
  IO.warn("loading")
  zero = 0
  puts(10 / zero)
  Test.run([Test.test("never listed") do ok() end])
end
