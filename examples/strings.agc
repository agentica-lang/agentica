def main() -> Void
  text = "  Agentica, hello  "
  clean = text.strip
  puts(clean.upcase)
  clean.split(", ").each do |part|
    puts(part.length.to_s)
  end
  if clean.include?("Agentica")
    puts(clean.replace("hello", "world"))
  end
end
