## The format string of `format(...)` (Ruby's Kernel#format), read into its literal text and its conversions. The
## checker and the lowering share it, so the conversions the checker typed are the ones the lowering writes. A
## conversion is `%[flags][width][.precision]type`: flags `-` and `0`, width 1 to 1000, precision 0 to 50 (only for
## `f`), type `d`, `x`, `f` or `s`; `%%` is a `%`.

MAX_WIDTH = 1000
MAX_PRECISION = 50

## One conversion: its type (`d`, `x`, `f` or `s`), the flags `-` (left) and `0` (zero), the width (0 when none), the
## precision (-1 when none), and the characters of the format string it covers, start included and stop excluded.
struct Conversion
  kind: String
  left: Bool
  zero: Bool
  width: Int
  precision: Int
  start: Int
  stop: Int
end

## A part of the format string: literal text or a conversion.
enum Piece
  Text(String)
  Convert(Conversion)
end

## The parts of a format string, or its first problem: message is "" when the string is valid, else the problem of the
## characters from start to stop.
struct Parsed
  pieces: List[Piece]
  message: String
  start: Int
  stop: Int
end

## Reads a format string.
def parse(text: String) -> Parsed
  chars = text.split("")
  pieces: List[Piece] = []
  literal: List[String] = []
  index = 0
  while index < chars.size
    if chars[index] != "%"
      literal = literal.push(chars[index])
      index += 1
      next
    end

    if index + 1 < chars.size and chars[index + 1] == "%"
      literal = literal.push("%")
      index += 2
      next
    end

    read = conversion(chars, index)
    return read if read.message != ""

    if literal.size > 0
      pieces = pieces.push(Piece.Text(literal.join("")))
      literal = []
    end

    pieces = pieces.concat(read.pieces)
    index = read.stop
  end

  if literal.size > 0
    pieces = pieces.push(Piece.Text(literal.join("")))
  end

  Parsed(pieces: pieces, message: "", start: 0, stop: 0)
end

## Whether a conversion only puts a value in the text, as `"#{x}"` does: a `%s` or `%d` with no flag, width or
## precision.
def bare?(c: Conversion) -> Bool
  (c.kind == "s" or c.kind == "d") and !c.left and !c.zero and c.width == 0 and c.precision < 0
end

private

# The conversion that starts at the `%` at `start`, as a Parsed of that one piece whose stop is the index after it.
def conversion(chars: List[String], start: Int) -> Parsed
  index = start + 1
  left = false
  zero = false
  while index < chars.size and "-0+ #".include?(chars[index])
    flag = chars[index]
    if flag == "-"
      left = true
    elsif flag == "0"
      zero = true
    else
      return bad("the flag \"#{flag}\" is not supported; format takes the flags - and 0", start, index + 1)
    end

    index += 1
  end

  width = 0
  while index < chars.size and digit?(chars[index])
    if width <= MAX_WIDTH
      width = width * 10 + chars[index].to_i!
    end

    index += 1
  end

  return bad("the width must be 1 to #{MAX_WIDTH}", start, index) if width > MAX_WIDTH

  precision = -1
  if index < chars.size and chars[index] == "."
    index += 1
    precision = 0
    while index < chars.size and digit?(chars[index])
      if precision <= MAX_PRECISION
        precision = precision * 10 + chars[index].to_i!
      end

      index += 1
    end

    return bad("the precision must be 0 to #{MAX_PRECISION}", start, index) if precision > MAX_PRECISION
  end

  return bad("a % at the end of the format needs a conversion (write %% for a %)", start, index) if index >= chars.size

  kind = chars[index]
  stop = index + 1
  return bad("%% takes no flag, width or precision", start, stop) if kind == "%"

  return bad("unknown conversion %#{kind}; format takes %d, %x, %f, %s and %%", start, stop) if !"dxfs".include?(kind)

  return bad("a precision is only for %f, not %#{kind}", start, stop) if precision >= 0 and kind != "f"

  return bad("the flag 0 pads numbers; %s pads with spaces", start, stop) if zero and kind == "s"

  made = Conversion(
    kind: kind,
    left: left,
    zero: zero and !left,
    width: width,
    precision: precision,
    start: start,
    stop: stop,
  )

  Parsed(pieces: [Piece.Convert(made)], message: "", start: start, stop: stop)
end

def bad(message: String, start: Int, stop: Int) -> Parsed
  Parsed(pieces: [], message: message, start: start, stop: stop)
end

def digit?(char: String) -> Bool = char != "" and "0123456789".include?(char)
