def divide(n: Int) -> Int
  return 10 / n
end

def test_adds() -> Result[Void]
  try Test.eq(1 + 1, 2)
  return Test.eq(divide(5), 2)
end

def test_compares_text() -> Result[Void]
  puts("shown when failing")
  return Test.eq("a", "b")
end

def test_returns_an_error() -> Result[Void]
  return error("not ready")
end

def test_crashes() -> Result[Void]
  return Test.eq(divide(0), 1)
end

def test_runs_after_a_crash() -> Result[Void]
  return ok()
end
