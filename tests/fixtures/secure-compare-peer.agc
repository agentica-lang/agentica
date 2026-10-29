# Reads a JSON Pairs document on stdin and prints, as JSON, the
# HMAC.secure_compare of each pair; tests/test_vm_crypto.py compares the
# answers with Python's hmac.compare_digest. JSON has no byte type, so the
# bytes come as lists of Ints.
struct Pair
  a: List[Int]
  b: List[Int]
end

struct Pairs
  pairs: List[Pair]
end

def main() -> Void
  pairs = JSON.decode(IO.read(), Pairs).unwrap!.pairs
  answers = pairs.map do |p: Pair|
    HMAC.secure_compare(Bytes.from_list(p.a).unwrap!, Bytes.from_list(p.b).unwrap!)
  end
  puts(JSON.encode(answers))
end
