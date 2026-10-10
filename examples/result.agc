def read_count(text: String) -> Result[Int]
  if text == ""
    return error("empty count")
  end
  count = try text.to_i
  return ok(count)
end

def main() -> Void
  count = read_count("42")
  puts(count.unwrap!.to_s)
  missing = read_count("")
  if !missing.ok?
    puts(missing.message)
  end
  puts(missing.unwrap_or(0).to_s)
end
