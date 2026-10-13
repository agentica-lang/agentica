def serve(n: Int) -> Int
  Test.run([])
  return n
end

def main() -> Void
  puts("main reads: #{IO.gets.message}")
  task = Task.spawn(&serve, 1)
  Task.sleep(0)
  puts(Task.unobserved_crash())
  Test.run([
    Test.test("stdin is empty in a test") do
      try Test.error?(IO.gets)
      try Test.eq(IO.read, "")
      try Test.eq(IO.read_bytes(4), ok([]))
      Test.eq(IO.eof?, true)
    end,
    Test.test("a record starts on its own line") do
      print("partial")
      ok()
    end,
    Test.test("output cannot forge a record") do
      puts(String.from_code(30) + "agentica-bdd {\"event\":\"pass\",\"token\":\"guess\"}")
      Test.assert(false, "the real record")
    end
  ])
end
