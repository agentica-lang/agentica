struct Point
  x: Int
  y: Float
end

# Follows a path of the peer: "." is the root, "#3" an array index, any other step an object key.
def follow(j: JSON.Value, path: String) -> Result[JSON.Value]
  if path == "."
    return ok(j)
  end
  node = j
  for step in path.split("/")
    if step.start_with?("#")
      node = try JSON.at(node, step.slice(1, step.length - 1).to_i!)
    else
      node = try JSON.get(node, step)
    end
  end
  return ok(node)
end

# Checks the kind and that it agrees with JSON.int and JSON.float.
def check(line: String) -> Int
  fields = line.split("\t")
  node = follow(JSON.parse(fields[0]).unwrap!, fields[1]).unwrap!
  got = JSON.kind(node)
  if got != fields[2]
    puts("#{fields[0]} #{fields[1]}: got #{got}, want #{fields[2]}")
    return 1
  end
  if got != "int" && JSON.int(node).ok?
    puts("#{fields[0]} #{fields[1]}: JSON.int succeeded on #{got}")
    return 1
  end
  if got == "float" && !JSON.float(node).ok?
    puts("#{fields[0]} #{fields[1]}: JSON.float failed on float")
    return 1
  end
  if node_kind(node) != got
    puts("#{fields[0]} #{fields[1]}: JSON.node is #{node.node.inspect}, want #{got}")
    return 1
  end
  return 0
end

# The kind that JSON.node gives, as JSON.kind names it: an Int is one JSON.int takes, a BigInt one it refuses.
def node_kind(node: JSON.Value) -> String
  case node.node
    JSON.Node.Null -> "null"
    JSON.Node.Bool(_) -> "bool"
    JSON.Node.Int(n) -> agreed(JSON.int(node) == ok(n), "int")
    JSON.Node.BigInt(_) -> agreed(!JSON.int(node).ok?, "int")
    JSON.Node.Float(x) -> agreed(JSON.float(node) == ok(x), "float")
    JSON.Node.String(_) -> "string"
    JSON.Node.Array(_) -> "array"
    JSON.Node.Object(_) -> "object"
  end
end

def agreed(same: Bool, kind: String) -> String
  return kind if same

  "not #{kind}"
end

def main() -> Void
  _ = IO.gets()
  count = 0
  failed = 0
  running = true
  while running
    case IO.gets()
      ok(line) ->
        failed += check(line)
        count += 1
      error(_) ->
        running = false
    end
  end
  if failed == 0
    puts("#{count} vectors ok")
  else
    puts("#{failed} of #{count} vectors failed")
  end
  big = JSON.parse("99999999999999999999").unwrap!
  puts("#{big.kind} #{JSON.int(big)}")
  built = JSON.object({"n": JSON.null(), "l": JSON.array([JSON.from(1), JSON.from(1.0), JSON.from(-0.0)])})
  puts(JSON.kind(built))
  puts(JSON.list(built.get("l").unwrap!).unwrap!.map do |item| item.kind end)
  puts(built.get("n").unwrap!.kind)
  point = JSON.from(Point(x: 3, y: 4.0))
  puts([point.kind, point.get("x").unwrap!.kind, point.get("y").unwrap!.kind])
  puts([JSON.from(true).kind, JSON.from("s").kind, JSON.from([1, 2]).kind, JSON.from({"a": 1}).kind])
  empty: List[Int] = []
  puts([JSON.from(empty).kind, JSON.object({}).kind, JSON.array([]).kind])
end
