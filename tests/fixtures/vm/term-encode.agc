# Term.encode: the bytes of each value as hex, one line "name hex", in the order of tests/test_term_encode.py, which
# compares each line with the CBOR that its independent peer (tests/fixtures/term_peer.py) writes for the same value.
struct Entry
  id: Int
  hits: Map[Int, Int]
  names: Map[String, UInt8]
  raw: Bytes
  tag: Optional[String]
  nothing: Nil
end

struct Box[T]
  value: T
end

enum Shape
  Circle(Float)
  Rect(Int, Int)
  Empty
end

def hex(data: Bytes) -> String = OpenSSL.Digest.hexencode(data)

def show(name: String, encoded: Result[Bytes]) -> Void
  puts("#{name} #{hex(encoded.unwrap!)}")
end

def uint64_of(text: String) -> UInt64
  text.bytes.to_a.reduce(0.to_uint64!) do |acc: UInt64, digit: Int|
    acc * 10 + (digit - 48).to_uint64!
  end
end

def ints() -> Void
  for n in [0, 23, 24, 255, 256, 65535, 65536, 4294967295, 4294967296, 9223372036854775807]
    show("int #{n}", Term.encode(n))
  end

  for n in [-1, -24, -25, -256, -257, -65536, -65537, -4294967296, -4294967297, -9223372036854775807]
    show("int #{n}", Term.encode(n))
  end

  show("int min", Term.encode(0 - 9223372036854775807 - 1))
  for n in [0, 24, 256, 65536, 4294967296, 9223372036854775807]
    show("uint64 #{n}", Term.encode(n.to_uint64!))
  end

  show("uint64 2^63", Term.encode(uint64_of("9223372036854775808")))
  show("uint64 max", Term.encode(uint64_of("18446744073709551615")))
  small: UInt8 = 200
  show("uint8 200", Term.encode(small))
  narrow: Int8 = -128
  show("int8 -128", Term.encode(narrow))
end

def floats() -> Void
  for bits in [0, 1, 4607182418800017408, 4609434218613702656, 4608083138725491507, 9218868437227405312]
    show("float #{bits}", Term.encode(Float.from_bits(bits.to_uint64!)))
  end

  show("float -0.0", Term.encode(Float.from_bits(uint64_of("9223372036854775808"))))
  show("float -inf", Term.encode(Float.from_bits(uint64_of("18442240474082181120"))))
  show("float nan payload", Term.encode(Float.from_bits(uint64_of("9221120237041090561"))))
  show("float nan negative", Term.encode(Float.from_bits(uint64_of("18444492273895866368"))))
  show("float max", Term.encode(Float.from_bits(9218868437227405311)))
  show("float min subnormal", Term.encode(Float.from_bits(1)))
  for bits in [0, 1, 1065353216, 1203982336, 2139095039, 2139095040, 2143289344, 2143289345]
    show("float32 #{bits}", Term.encode(Float32.from_bits(bits.to_uint32!)))
  end

  show("float32 -0.0", Term.encode(Float32.from_bits(2147483648.to_uint32!)))
  show("float32 -inf", Term.encode(Float32.from_bits(4286578688.to_uint32!)))
end

def texts() -> Void
  for size in [0, 1, 23, 24, 255, 256, 65535, 65536]
    show("string #{size}", Term.encode("a" * size))
    show("bytes #{size}", Term.encode(Bytes.from_list(List.repeat(7, size)).unwrap!))
  end

  show("string ü", Term.encode("ü"))
  show("string water", Term.encode("水"))
  show("string quote", Term.encode("\"\\"))
end

def containers() -> Void
  show("nil", Term.encode(nil))
  show("true", Term.encode(true))
  show("false", Term.encode(false))
  empty: List[Int] = []
  show("list empty", Term.encode(empty))
  for size in [1, 23, 24, 255, 256, 65536]
    show("list #{size}", Term.encode(List.repeat(1, size)))
  end

  show("list nested", Term.encode([[1], [2, 3], []]))
  none_int: Optional[Int] = none
  show("optional none", Term.encode(none_int))
  show("optional some", Term.encode(some(5)))
  show("optional list", Term.encode([some(1), none_int]))
  ordered = {3: 4, 1: 2}
  show("map int order", Term.encode(ordered))
  show("map int negative", Term.encode({-1: 1, 0: 2, 1: 3}))
  show("map string order", Term.encode({"b": [1], "a": [2, 3]}))
  no_names: Map[String, Int] = {}
  show("map empty", Term.encode(no_names))
  grown = {"x": 1, "y": 2}.delete("x").put("x", 3)
  show("map reinserted", Term.encode(grown))
end

def records() -> Void
  entry = Entry(id: 7, hits: {2: 1, 1: 5}, names: {"k": 9}, raw: Bytes.from_list([1, 2]).unwrap!, tag: some("t"), nothing: nil)
  show("struct", Term.encode(entry))
  absent = Entry(id: -7, hits: {}, names: {}, raw: Bytes.from_list([]).unwrap!, tag: none, nothing: nil)
  show("struct empty", Term.encode(absent))
  show("struct list", Term.encode([absent, absent]))
  show("generic", Term.encode(Box(value: [1, 2])))
  show("generic nested", Term.encode(Box(value: Box(value: "x"))))
  show("enum circle", Term.encode(Shape.Circle(1.5)))
  show("enum rect", Term.encode(Shape.Rect(2, -3)))
  show("enum empty", Term.encode(Shape.Empty))
  show("enum list", Term.encode([Shape.Empty, Shape.Rect(1, 2)]))
end

def main() -> Void
  ints()
  floats()
  texts()
  containers()
  records()
end
