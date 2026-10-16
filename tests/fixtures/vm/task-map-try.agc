def measure(text: String) -> Result[Int]
  if text == "x"
    return error("not a number")
  end
  return ok(text.length * 2)
end

def main() -> Void
  # try works in the block: the Result type comes from the body, or from the type of the variable.
  inferred = Task.map(["ab", "x", "abc"], 2, 5000) do |text|
    n = try measure(text)
    ok(n + 1)
  end
  puts(inferred)
  typed: List[Result[Int]] = Task.map(["ab", "abcde"], 2, 5000) do |text|
    n = try measure(text)
    if n > 8
      return error("too long")
    end
    ok(n)
  end
  puts(typed)
  puts(typed.all? do |r| r.ok? end)
end
