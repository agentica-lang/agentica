struct Node
  depth: Int
  next: List[Node]
end

def main() -> Void
  text = "{\"depth\":0,\"next\":[]}"
  i = 1
  while i <= 1000
    text = "{\"next\":[" + text + "],\"depth\":#{i}}"
    i = i + 1
  end
  node = Result.unwrap!(JSON.decode(text, Node))
  count = 0
  while node.next.size > 0
    count = count + node.depth
    node = node.next[0]
  end
  puts(count)
  puts(JSON.encode(JSON.schema(Node)))
  broken = String.replace(text, "\"depth\":0", "\"depth\":0.5")
  puts(Result.message(JSON.decode(broken, Node)).length)
end
