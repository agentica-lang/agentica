# Ref.new: equality, the printed form, Map keys and Set elements, the order of creation, and Refs made by tasks.

TABLE: ATS[Ref, String] = ATS.new()

struct Node
  id: Ref
  name: String
end

enum Tag
  Of(Ref)
  Nothing
end

# Makes `n` Refs one after another.
def make_refs(n: Int) -> List[Ref]
  refs: List[Ref] = []
  for _ in 0...n
    refs = refs.push(Ref.new())
  end

  refs
end

def ascending?(refs: List[Ref]) -> Bool = refs.sort == refs and refs.uniq.size == refs.size

def main() -> Void
  a = Ref.new()
  b = Ref.new()
  puts(a == a)
  puts(a == b)
  puts(a != b)
  puts(a)
  puts(b.inspect)
  puts("#{a} #{b}")
  IO.inspect([a, b])
  IO.inspect(Node(id: a, name: "a"))
  IO.inspect(Tag.Of(b))
  puts(Node(id: a, name: "x") == Node(id: a, name: "x"))
  puts(Tag.Of(a) == Tag.Of(b))

  m: Map[Ref, String] = {}
  m = m.put(b, "b").put(a, "a")
  puts(m[a])
  puts(m.has_key?(Ref.new()))
  literal: Map[Ref, Int] = {a: 1, b: 2}
  puts(literal[b])
  set = Set.new([a, b, a])
  puts(set.size)
  puts(set.include?(b))
  TABLE.put(a, "in the table")
  puts(TABLE.get(a).unwrap_or("none"))
  puts(TABLE.get(b).unwrap_or("none"))

  nodes = [Node(id: b, name: "second"), Node(id: a, name: "first")]
  puts(nodes.sort_by { |n| n.id }.map { |n| n.name })
  puts([b, a, b].sort == [a, b, b])
  puts([a, b, a].uniq == [a, b])
  puts([a, b, a].tally[a])
  puts(nodes.group_by { |n| n.id }.size)

  ch: Channel[List[Ref]] = Channel.new(8)
  tasks = (0...4).to_a.map do |_|
    Task.spawn do
      _ = ch.send(make_refs(500), 5000)
    end
  end

  for t in tasks
    Task.await(t)
  end

  all: List[Ref] = []
  for _ in 0...4
    case ch.recv(5000)
      ok(refs) ->
        puts(ascending?(refs))
        all = all + refs
      error(e) -> puts(e)
    end
  end

  puts(Set.new(all).size)
  last = Ref.new()
  puts(([last] + all).sort.last == last)
end
