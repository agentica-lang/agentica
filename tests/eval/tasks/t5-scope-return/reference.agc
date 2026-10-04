def classify(n: Int) -> String
  if n < 0
    return "negative"
  elsif n == 0
    return "zero"
  else
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
    end
  end
  puts("negatives: " + String.from_int(negatives))
end
