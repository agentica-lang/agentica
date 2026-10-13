def main() -> Void
  puts("before Test.run")
  Test.run([
    Test.test("never runs here") do
      puts("not printed")
      ok()
    end
  ])
  puts("Test.run never returns")
end
