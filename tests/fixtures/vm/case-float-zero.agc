# A case on Float literals compares with SAME: 0.0 and -0.0 differ, and NaN (no literal names it) matches no arm.
def label(x: Float) -> String
  case x
    0.0 -> return "zero"
    -0.0 -> return "negative zero"
    _ -> return "other"
  end
end

def main() -> Void
  puts(label(0.0))
  puts(label(-0.0))
  puts(label(1.5))
  nan = Float.from_bits(9221120237041090560)
  puts(label(nan))
end
