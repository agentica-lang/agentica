def read_count(text: String) -> Result[Int]
  if text == ""
    return error("empty count")
  end
  count = try String.to_int(text)
  return ok(count)
end

def main() -> Nil
  count = read_count("42")
  puts(String.from_int(Result.unwrap!(count)))
  missing = read_count("")
  if not Result.ok?(missing)
    puts(Result.message(missing))
  end
  puts(String.from_int(Result.unwrap_or(missing, 0)))
end
