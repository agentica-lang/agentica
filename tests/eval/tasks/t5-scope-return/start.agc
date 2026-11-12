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
    n = IO.gets!().strip.to_i!
    label = classify(n)
    puts(label)
    if label == "negative"
      negatives = negatives + 1
      negatives: Int = negatives
    end
    last = n
  end
  puts("negatives: " + negatives.to_s)
  puts(last.to_s)
end
