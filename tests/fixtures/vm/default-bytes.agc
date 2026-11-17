import Wire from "lib/default_bytes"
import {CRLF} from "lib/default_bytes"

# A Bytes default is the bytes of a string literal, `"text".bytes`, written in place or through a constant of this file
# or of another, for a parameter and for a field.
EMPTY = "".bytes

def line(text: String, mark: Bytes = CRLF, prefix: Bytes = EMPTY, tag: Bytes = "é".bytes) -> List[Int]
  (prefix + text.bytes + mark + tag).to_a
end

def main() -> Void
  puts(Wire.send())
  puts(Wire.send("ab".bytes))
  puts(Wire.send("ab".bytes, "".bytes))
  frame = Wire.Frame()
  puts(frame.head.to_a)
  puts(frame.tail.to_a)
  puts(Wire.Frame(head: "PUT".bytes).head.to_a)
  puts(line("x"))
  puts(line("x", "!".bytes, "> ".bytes))
end
