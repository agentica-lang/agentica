def parse(text: String) -> Result[Int]
  if text == "1"
    return ok(1)
  end
  return error("cannot read \"#{text}\" here")
end

def main() -> Void
  puts(parse("1").unwrap!)
  value = Result.unwrap!(parse("x"))
  puts(value)
end
