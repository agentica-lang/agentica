# A file that main.agc imports: its lines are counted with the program's.

## "small" or "large".
export def size_of(n: Int) -> String
  if n < 100
    return "small"
  end

  return "large"
end
