# Term.decode: values written by Term.encode that read back as themselves, the same values from CBOR that is written by
# hand (keys in another order, an ignored key), and the bytes that it refuses, with the path of the first bad value.
# tests/test_term_decode.py checks the same reads against an independent peer; this one runs in the VM sweeps (step
# limits, gc-stress, sanitizers).
struct Entry
  id: Int
  hits: Map[Int, Int]
  names: Map[String, UInt8]
  raw: Bytes
  score: Float
  ratio: Float32
  big: UInt64
  tag: Optional[String]
  nothing: Nil
  field: JSON.Field[Int]
  shape: Shape
  boxed: Box[List[Int]]
end

struct Box[T]
  value: T
end

enum Shape
  Circle(Float)
  Rect(Int, Int)
  Empty
end

struct Tree
  children: List[Tree]
  label: Optional[String]
end

struct Pair
  x: Int
  y: String
end

def hex(text: String) -> Bytes = OpenSSL.Digest.hexdecode(text).unwrap!

def entry() -> Entry
  Entry(
    id: -7,
    hits: {2: 1, 1: 5},
    names: {"k": 9},
    raw: Bytes.from_list([1, 2]).unwrap!,
    score: 1.5,
    ratio: 0.25,
    big: Int.wrap_uint64(-1),
    tag: some("t"),
    nothing: nil,
    field: JSON.Field.Value(3),
    shape: Shape.Rect(2, -3),
    boxed: Box(value: [1, 2]),
  )
end

def back(name: String, original: Entry, bytes: Bytes, decoded: Result[Entry]) -> Void
  case decoded
    ok(value) -> puts("#{name} #{value == original} #{Term.encode(value).unwrap! == bytes} #{value.hits} #{value.shape}")
    error(e) -> puts("#{name} #{e.kind} #{e.message}")
  end
end

def report[T](name: String, decoded: Result[T]) -> Void
  case decoded
    ok(_) -> puts("#{name} ok")
    error(e) -> puts("#{name} #{e.kind} #{e.message}")
  end
end

def tree(depth: Int) -> Tree
  return Tree(children: [], label: none) if depth == 0

  Tree(children: [tree(depth - 1), tree(depth - 1)], label: some("n#{depth}"))
end

def main() -> Void
  bytes = Term.encode(entry()).unwrap!
  back("entry", entry(), bytes, Term.decode(bytes, Entry))
  big = Term.encode(tree(6)).unwrap!
  case Term.decode(big, Tree)
    ok(value) -> puts("tree #{Term.encode(value).unwrap! == big} #{big.size}")
    error(e) -> puts("tree #{e.message}")
  end

  # Keys in another order, and an ignored key that holds a list, a map and every simple value.
  report("reordered", Term.decode(hex("a261796173617801"), Pair))
  report("ignored", Term.decode(hex("a361780161796173617a8401a1616bf6f5f4"), Pair))
  report("shape", Term.decode(hex("8266436972636c6581fb3ff8000000000000"), Shape))
  report("cut", Term.decode(bytes.take(bytes.size - 1), Entry))
  report("trailing", Term.decode(bytes + hex("00"), Entry))
  report("empty", Term.decode(hex(""), Pair))
  report("not a map", Term.decode(hex("80"), Pair))
  report("long head", Term.decode(hex("a26178180161796173"), Pair))
  report("tag", Term.decode(hex("a26178c10161796173"), Pair))
  report("indefinite", Term.decode(hex("a261789fff61796173"), Pair))
  report("missing", Term.decode(hex("a1617801"), Pair))
  report("duplicate", Term.decode(hex("a361780161780261796173"), Pair))
  report("utf8", Term.decode(hex("a2617801617962c328"), Pair))
  report("huge length", Term.decode(hex("a2617801617979ffff"), Pair))
  report("unknown tag", Term.decode(hex("8268547269616e676c6580"), Shape))
  report("values", Term.decode(hex("8264526563748101"), Shape))
  report("path", Term.decode(hex("a2686368696c6472656e82a2686368696c6472656e80656c6162656cf6a2686368696c6472656e80656c6162656c05656c6162656c6172"), Tree))
end
