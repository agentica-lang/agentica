## The Unicode rules of the lexer and of the written form of a String: graphic and blank characters.

import {GRAPHIC_RANGES} from "unicode_table"

## Whether the code point is a graphic character, one that a program can write as it is.
export def graphic?(code: Int) -> Bool
  return in_ranges?(GRAPHIC_RANGES, code, 0, GRAPHIC_RANGES.size / 2)
end

## An Int as upper-case hexadecimal digits, padded with zeros to width.
export def hex(value: Int, width: Int) -> String
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

## Returns the code as upper-case hexadecimal digits, with at least one.
export def hex_text(value: Int) -> String
  return hex(value, 1)
end

## Returns the character literal of the code point, such as `#\tab` or `#\u00E9`.
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
      if code < 65_536
        return "#\\u#{hex(code, 4)}"
      end
      return "#\\U#{hex(code, 8)}"
  end
end

## A String as `write` shows it: quotes, with \\a \\b \\t \\n \\v \\f \\r \\e, \\" and \\\\, and \\uXXXX or
## \\UXXXXXXXX for characters that are neither graphic nor blank.
export def written_text(text: String) -> String
  parts: List[String] = ["\""]
  for character in text.split("")
    parts = parts.push(written_character(GRAPHIC_RANGES, String.code(character), character))
  end
  parts = parts.push("\"")
  return parts.join("")
end

def in_ranges?(ranges: List[Int], code: Int, low: Int, high: Int) -> Bool
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

def blank?(code: Int) -> Bool
  return (
    code == 32 or
    code == 160 or
    code == 5760 or
    (code >= 8192 and code <= 8202) or
    code == 8239 or
    code == 8287 or
    code == 12_288
  )
end

def written_character(ranges: List[Int], code: Int, character: String) -> String
  case code
    34 -> return "\\\""
    92 -> return "\\\\"
    7 -> return "\\a"
    8 -> return "\\b"
    9 -> return "\\t"
    10 -> return "\\n"
    11 -> return "\\v"
    12 -> return "\\f"
    13 -> return "\\r"
    27 -> return "\\e"
    _ ->
      if (code > 32 and code < 127) or blank?(code) or in_ranges?(ranges, code, 0, ranges.size / 2)
        return character
      end
      if code < 65_536
        return "\\u#{hex(code, 4)}"
      end
      return "\\U#{hex(code, 8)}"
  end
end
