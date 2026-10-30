## The byte encoding of the bytecode writer: little-endian integers, UTF-8 text, and the chunks the file is built from.
## A piece is a small `List[Int]` of bytes: appending a small piece to a list costs O(piece)
## (docs/grammar/06b-builtins.md, List.concat), where a `Bytes` would copy what it already holds. The chunks keep the
## pieces as a short open list, and seal it into a `Bytes` when it grows or a long piece comes, so the file is never
## held as one `List[Int]`. join gives the file with one `Bytes.concat`, so nothing copies the output twice.

# A piece of this many bytes or fewer joins the open list; a longer one is a chunk of its own.
SMALL_PIECE = 32

# add seals the open list when it holds more than this many bytes, so it stays small and the sealing is amortized.
# add_all may leave it longer (the open list of the other chunks joins it) until the next add seals it.
OPEN_LIMIT = 4096

## The sealed chunks in order, the bytes not sealed yet (they come after the chunks), and the first sealing that
## failed: "" while every item was a byte.
export struct Chunks
  done: List[Bytes]
  open: List[Int]
  failed: String
end

## The 2 bytes of a number in 0 .. 65535, low byte first.
export def u16(number: Int) -> List[Int]
  return [number % 256, number / 256]
end

## The 4 bytes of a number in 0 .. 4294967295, low byte first.
export def u32(number: Int) -> List[Int]
  # The fast branch gives the same bytes as the general formula for 0 .. 65535 (the two high bytes are 0 there) and
  # skips the arithmetic for them. Callers never pass a negative number (lines, columns, counts and ids are >= 0): a
  # negative one would take the fast branch and give negative bytes.
  if number < 65_536
    return [number % 256, number / 256, 0, 0]
  end

  return [number % 256, (number / 256) % 256, (number / 65_536) % 256, number / 16_777_216]
end

## The 8 bytes of a signed number, low byte first (a two's complement integer).
export def i64(number: Int) -> List[Int]
  return [
    number.bit_and(255),
    number.shift_right(8).bit_and(255),
    number.shift_right(16).bit_and(255),
    number.shift_right(24).bit_and(255),
    number.shift_right(32).bit_and(255),
    number.shift_right(40).bit_and(255),
    number.shift_right(48).bit_and(255),
    number.shift_right(56).bit_and(255),
  ]
end

## The 8 bytes of the IEEE 754 binary64 of a number, low byte first.
export def f64(number: Float) -> List[Int]
  return i64(Float.to_bits(number))
end

## The UTF-8 bytes of a text.
export def utf8(text: String) -> List[Int]
  return text.bytes.to_a
end

## A text as the file stores it: the number of its UTF-8 bytes as a u32, then the bytes.
export def string(text: String) -> List[Int]
  data = utf8(text)
  return u32(data.size).concat(data)
end

## Chunks with no byte.
export def start() -> Chunks
  return Chunks(done: [], open: [], failed: "")
end

## The chunks with the piece added at the end: a small piece joins the open list, a long one is sealed as a chunk.
export def add(chunks: Chunks, piece: List[Int]) -> Chunks
  if piece.size > SMALL_PIECE
    return seal(close(chunks), piece)
  end

  open = chunks.open.concat(piece)
  if open.size > OPEN_LIMIT
    return close(chunks.with(open: open))
  end

  return chunks.with(open: open)
end

## The chunks with a text added as the file stores it (see string); the text of a long one is not made a list.
export def add_text(chunks: Chunks, text: String) -> Chunks
  data = text.bytes
  if data.size <= SMALL_PIECE
    return add(chunks, u32(data.size).concat(data.to_a))
  end

  sized = add(chunks, u32(data.size))
  closed = close(sized)
  return closed.with(done: closed.done.push(data))
end

## The chunks with the chunks of another list added at the end.
export def add_all(chunks: Chunks, more: Chunks) -> Chunks
  out = chunks
  if more.done.size > 0
    closed = close(chunks)
    out = closed.with(done: closed.done.concat(more.done))
  end

  if out.failed == ""
    out = out.with(failed: more.failed)
  end

  if more.open.size == 0
    return out
  end

  return add(out, more.open)
end

## All the chunks as one `Bytes`, or an error naming the first item that was not a byte.
export def join(chunks: Chunks) -> Result[Bytes]
  # The failure is read after the close: sealing the open list is where a bad item of it is found.
  closed = close(chunks)
  if closed.failed != ""
    return error(closed.failed)
  end

  return ok(Bytes.concat(closed.done))
end

# The chunks with the open list sealed as a chunk.
def close(chunks: Chunks) -> Chunks
  if chunks.open.size == 0
    return chunks
  end

  return seal(chunks.with(open: []), chunks.open)
end

# The chunks with the items sealed as a chunk at the end. Every writer piece holds bytes, so a failure is a bug of the
# writer: it is kept for join, which reports it, and the chunk is left out.
def seal(chunks: Chunks, items: List[Int]) -> Chunks
  made = Bytes.from_list(items)
  if made.ok?
    return chunks.with(done: chunks.done.push(made.unwrap!))
  end

  if chunks.failed == ""
    return chunks.with(failed: made.message)
  end

  return chunks
end
