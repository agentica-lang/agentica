## The byte encoding of the bytecode writer: little-endian integers, UTF-8 text, and the chunk lists the file is
## built from. The output is a list of chunks that Binary.concat joins once; a chunk grows only by appending a small
## piece, which costs O(piece) (docs/grammar/06b-builtins.md, List.concat), so nothing copies the output twice.

import Binary from "std/binary"

# A piece of this many bytes or fewer joins the last chunk; a longer one is a chunk of its own.
SMALL_PIECE = 32

## The 2 bytes of a number in 0 .. 65535, low byte first.
export def u16(number: Int) -> List[Int]
  return [number % 256, number / 256]
end

## The 4 bytes of a number in 0 .. 4294967295, low byte first.
export def u32(number: Int) -> List[Int]
  # The fast branch gives the same bytes as the general formula for 0 .. 65535 (the two high bytes are 0 there) and
  # skips the arithmetic for them. Callers never pass a negative number (lines, columns, counts and ids are >= 0): a
  # negative one would take the fast branch and give negative bytes.
  if number < 65536
    return [number % 256, number / 256, 0, 0]
  end
  return [number % 256, (number / 256) % 256, (number / 65536) % 256, number / 16777216]
end

## The 8 bytes of a signed number, low byte first (a two's complement integer).
export def i64(number: Int) -> List[Int]
  return Binary.write_i64_le(number)
end

## The 8 bytes of the IEEE 754 binary64 of a number, low byte first.
export def f64(number: Float) -> List[Int]
  return Binary.write_f64_le(number)
end

## The UTF-8 bytes of a text. A text of ASCII characters only is its own character codes.
export def utf8(text: String) -> List[Int]
  codes = text.split("").map do |character: String| String.code(character) end
  if codes.all? do |code: Int| code < 128 end
    return codes
  end
  out: List[Int] = []
  for code in codes
    out = out.concat(encoded(code))
  end
  return out
end

## A text as the file stores it: the number of its UTF-8 bytes as a u32, then the bytes.
export def string(text: String) -> List[Int]
  data = utf8(text)
  return u32(data.size).concat(data)
end

## An empty list of chunks. It always holds a last chunk, which add appends to.
export def start() -> List[List[Int]]
  return [[]]
end

## The chunks with the piece added at the end: a small piece joins the last chunk, a long one becomes a chunk.
export def add(chunks: List[List[Int]], piece: List[Int]) -> List[List[Int]]
  if piece.size > SMALL_PIECE
    return chunks.push(piece)
  end
  last = chunks.size - 1
  return chunks.set(last, chunks[last].concat(piece))
end

## The chunks with the chunks of another list added at the end.
export def add_all(chunks: List[List[Int]], more: List[List[Int]]) -> List[List[Int]]
  out = chunks
  for chunk in more
    out = add(out, chunk)
  end
  return out
end

## All the chunks as one list of bytes.
export def join(chunks: List[List[Int]]) -> List[Int]
  return Binary.concat(chunks)
end

# The UTF-8 bytes of one code point (1 to 4 bytes; a String holds no surrogates).
def encoded(code: Int) -> List[Int]
  if code < 128
    return [code]
  elsif code < 2048
    return [192 + code / 64, 128 + code % 64]
  elsif code < 65536
    return [224 + code / 4096, 128 + (code / 64) % 64, 128 + code % 64]
  end
  return [240 + code / 262144, 128 + (code / 4096) % 64, 128 + (code / 64) % 64, 128 + code % 64]
end
