# The limits of Term.encode, which return an error with the path of the first value past them: 10,000 levels of
# nesting (an enum is one level, an Optional none), 4,000,000 values (a Map key is one, a field name is none) and the
# path of that value through a struct, a Map with a String key, a List and an enum payload. The expected lines are
# written by tests/test_term_encode.py, which also checks the size limit of 64 MiB (a slow case). It runs 88 million
# steps, so it is not in tests/fixtures/vm/, whose files every sweep runs many times.
struct Node
  next: Optional[Node]
end

struct Holder
  by_name: Map[String, List[Int]]
end

enum Item
  Big(List[Int])
end

struct Items
  items: List[Item]
end

def chain(levels: Int) -> Node
  node = Node(next: none)
  i = 1
  while i < levels
    node = Node(next: some(node))
    i += 1
  end
  node
end

def zeros(size: Int) -> List[Int]
  items: List[Int] = []
  i = 0
  while i < size
    items = items.push(0)
    i += 1
  end
  items
end

def shorten(text: String) -> String
  return text if text.length <= 100

  "#{text.slice(0, 20)}...#{text.slice(text.length - 60, 60)}"
end

def summary(name: String, encoded: Result[Bytes]) -> Void
  case encoded
    ok(data) -> puts("#{name} ok #{data.size}")
    error(e) -> puts("#{name} #{e.kind} #{e.message.length} #{shorten(e.message)}")
  end
end

def main() -> Void
  summary("depth 10000", Term.encode(chain(10000)))
  summary("depth 10001", Term.encode(chain(10001)))
  below = zeros(3999999)
  summary("list below", Term.encode(below))
  at = zeros(4000000)
  summary("list at", Term.encode(at))
  summary("struct map list", Term.encode(Holder(by_name: {"k\"q": at})))
  summary("list enum", Term.encode(Items(items: [Item.Big(at)])))
  summary("long key", Term.encode(Holder(by_name: {("a" * 63) + "é" + "z": at})))
end
