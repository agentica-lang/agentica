def main() -> Void
  Test.run([
    Test.test("prints for ever") do
      chunk = List.repeat("x", 100000).join("")
      while true
        puts(chunk)
        Task.sleep(5)
      end
      ok()
    end,
    Test.test("after") do
      ok()
    end
  ])
end
