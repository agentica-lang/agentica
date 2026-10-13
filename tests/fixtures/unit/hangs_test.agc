def main() -> Void
  Test.run([
    Test.test("hangs") do
      Task.sleep(60000)
      ok()
    end,
    Test.test("after") do
      ok()
    end
  ])
end
