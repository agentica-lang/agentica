# The limits of Term.decode, which return an error with the path of the first value past them: 10,000 levels of nesting
# and 4,000,000 values (the struct and the list count as values too). The expected lines are written by
# tests/test_term_decode.py. It runs about as many steps as tests/fixtures/term/limits.agc, so it is not in
# tests/fixtures/vm/ either.
struct Node
  next: Optional[Node]
end

struct Numbers
  values: List[Int]
end

def hex(text: String) -> Bytes = OpenSSL.Digest.hexdecode(text).unwrap!

def repeat(unit: Bytes, times: Int) -> Bytes
  out = Bytes.from_list([]).unwrap!
  piece = unit
  left = times
  while left > 0
    if left % 2 == 1
      out = Bytes.concat(out, piece)
    end

    piece = Bytes.concat(piece, piece)
    left = left / 2
  end

  out
end

def chain(levels: Int) -> Bytes = Bytes.concat(repeat(hex("a1646e657874"), levels), hex("f6"))

def numbers(count_hex: String, count: Int) -> Bytes
  Bytes.concat(hex("a166" + "76616c756573" + "9a" + count_hex), repeat(hex("00"), count))
end

def shorten(text: String) -> String
  return text if text.length <= 100

  "#{text.slice(0, 20)}...#{text.slice(text.length - 60, 60)}"
end

def report(name: String, decoded: Result[Numbers]) -> Void
  case decoded
    ok(value) -> puts("#{name} ok #{value.values.size}")
    error(e) -> puts("#{name} #{e.kind} #{e.message.length} #{shorten(e.message)}")
  end
end

def report_node(name: String, bytes: Bytes) -> Void
  case Term.decode(bytes, Node)
    ok(node) -> puts("#{name} ok #{Term.encode(node).unwrap! == bytes}")
    error(e) -> puts("#{name} #{e.kind} #{e.message.length} #{shorten(e.message)}")
  end
end

def main() -> Void
  report_node("depth 10000", chain(10000))
  report_node("depth 10001", chain(10001))
  report("values below", Term.decode(numbers("003d08fe", 3999998), Numbers))
  report("values at", Term.decode(numbers("003d08ff", 3999999), Numbers))
end
