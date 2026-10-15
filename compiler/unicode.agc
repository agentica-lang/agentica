import "unicode_table" as Table

export def graphic?(code: Int) -> Bool
  ranges = Table.graphic_ranges()
  return search(ranges, code, 0, ranges.size / 2)
end

export def hex_text(value: Int) -> String
  return hex(value, 1)
end

export def written(code: Int) -> String
  case code
    0 -> return "#\\nul"
    8 -> return "#\\backspace"
    9 -> return "#\\tab"
    10 -> return "#\\newline"
    11 -> return "#\\vtab"
    12 -> return "#\\page"
    13 -> return "#\\return"
    32 -> return "#\\space"
    127 -> return "#\\rubout"
    _ ->
      if code < 65536
        return "#\\u" + hex(code, 4)
      end
      return "#\\U" + hex(code, 8)
  end
end

def search(ranges: List[Int], code: Int, low: Int, high: Int) -> Bool
  while low < high
    middle = (low + high) / 2
    if ranges[middle * 2 + 1] < code
      low = middle + 1
    else
      high = middle
    end
  end
  return low * 2 < ranges.size and ranges[low * 2] <= code
end

def hex(value: Int, width: Int) -> String
  digits = "0123456789ABCDEF"
  parts: List[String] = []
  rest = value
  while rest > 0
    parts = parts.push(digits.slice(rest % 16, 1))
    rest = rest / 16
  end
  while parts.size < width
    parts = parts.push("0")
  end
  return parts.reverse.join("")
end
