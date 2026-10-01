def main() -> Nil
  text = "  Agentica, hello  "
  clean = String.trim(text)
  puts(String.upcase(clean))
  parts = String.split(clean, ", ")
  for part in parts
    puts(String.from_int(String.length(part)))
  end
  if String.contains?(clean, "Agentica")
    puts(String.replace(clean, "hello", "world"))
  end
end
