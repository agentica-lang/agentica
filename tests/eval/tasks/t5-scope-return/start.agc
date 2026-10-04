def classify(n: Int) -> String
  if n < 0
    return "negative"
  elsif n == 0
    return "zero"
  elsif n > 0
    return "positive"
  end
end

def main() -> Void
  negatives = 0
  while not IO.eof?()
    n = String.to_int!(String.trim(IO.gets!()))
    label = classify(n)
    puts(label)
    if label == "negative"
      negatives = negatives + 1
      negatives: Int = negatives
    end
    last = n
  end
  puts("negatives: " + String.from_int(negatives))
  puts(String.from_int(last))
end
