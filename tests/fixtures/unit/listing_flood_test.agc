def flood() -> Void
  chunk = List.repeat("x", 100000).join("")
  while true
    puts(chunk)
    Task.sleep(5)
  end
end

def main() -> Void
  flood()
  Test.run([
    Test.test("never listed") do
      ok()
    end
  ])
end
