enum Kind
  Big
  Small
end

def label(kind: Kind) -> String
  return case kind
    Kind.Big -> "big"
    Kind.Small -> "small"
  end
end

def main() -> Void
  size = case 3
    3 ->
      base = 4
      base + 1
    _ -> 0
  end
  size += case "a"
    "a" -> 1
    _ -> 2
  end
  names = [Kind.Big, Kind.Small].map do |kind|
    case kind
      Kind.Big -> "B"
      Kind.Small -> "S"
    end
  end
  puts("#{size} #{names} #{label(Kind.Big)}")
end
