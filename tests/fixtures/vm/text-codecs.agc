# Bytes.decode and String.encode: each built-in encoding both ways, the byte order mark of the plain UTF-16 and UTF-32
# (read, written, and big-endian without one), names matched without case and with `_` as `-`, and the error Results:
# the byte offset of a bad input, the index of a character the encoding cannot hold, and an unknown name.
def bytes_of(list: List[Int]) -> Bytes
  return Bytes.from_list(list).unwrap!
end

def show_bytes(encoding: String, r: Result[Bytes]) -> Void
  case r
    ok(b) -> puts("#{encoding}: #{b.to_a}")
    error(m) -> puts("#{encoding}: error: #{m}")
  end
end

def show_text(encoding: String, r: Result[String]) -> Void
  case r
    ok(s) -> puts("#{encoding}: #{s.inspect}")
    error(m) -> puts("#{encoding}: error: #{m}")
  end
end

def main() -> Void
  text = "aé€😀"
  for encoding in ["utf-8", "utf-16", "utf-16le", "utf-16be", "utf-32", "utf-32le", "utf-32be"]
    encoded = text.encode(encoding)
    show_bytes(encoding, encoded)
    show_text(encoding, encoded.unwrap!.decode(encoding))
  end

  show_bytes("latin-1", "aé".encode("latin-1"))
  show_text("latin-1", bytes_of([97, 233, 255]).decode("latin-1"))
  show_bytes("ascii", "ab".encode("ascii"))
  show_text("ascii", bytes_of([97, 98]).decode("ascii"))
  # The plain forms read either mark and are big-endian without one; LE, BE and UTF-8 keep a mark as U+FEFF.
  show_text("utf-16", bytes_of([255, 254, 97, 0]).decode("utf-16"))
  show_text("utf-16", bytes_of([0, 97]).decode("utf-16"))
  show_text("utf-32", bytes_of([255, 254, 0, 0, 97, 0, 0, 0]).decode("utf-32"))
  show_text("utf-16le", bytes_of([255, 254, 97, 0]).decode("utf-16le"))
  show_text("utf-8", bytes_of([239, 187, 191, 97]).decode("utf-8"))
  show_bytes("utf-16", "".encode("utf-16"))
  show_text("utf-16", bytes_of([]).decode("utf-16"))
  # Names.
  show_bytes("UTF_16_LE", "a".encode("UTF_16_LE"))
  show_bytes("ISO-8859-1", "é".encode("ISO-8859-1"))
  show_text("US-ASCII", bytes_of([65]).decode("US-ASCII"))
  # Errors.
  show_text("utf-8", bytes_of([97, 226, 130]).decode("utf-8"))
  show_text("utf-8", bytes_of([237, 160, 128]).decode("utf8"))
  show_text("utf-16le", bytes_of([97, 0, 98]).decode("utf-16le"))
  show_text("utf-16le", bytes_of([97, 0, 0, 220]).decode("utf-16le"))
  show_text("utf-16be", bytes_of([216, 0, 0, 97]).decode("utf-16be"))
  show_text("utf-16", bytes_of([255, 254, 0, 216]).decode("utf-16"))
  show_text("utf-32le", bytes_of([0, 0, 17, 0]).decode("utf-32le"))
  show_text("utf-32be", bytes_of([0, 0, 216, 0]).decode("utf-32be"))
  show_text("utf-32", bytes_of([0, 0, 0, 97, 0]).decode("utf-32"))
  show_text("ascii", bytes_of([97, 128]).decode("ascii"))
  show_bytes("ascii", "aé".encode("ascii"))
  show_bytes("latin-1", "a€".encode("latin-1"))
  show_bytes("koi8-r", "a".encode("koi8-r"))
  show_text("utf-8-sig", bytes_of([97]).decode("utf-8-sig"))
end
