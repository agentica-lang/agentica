# JSON.node opens one level of a JSON.Value: a walker over a document it does not know.
def show(value: JSON.Value, depth: Int) -> Void
  pad = "  " * depth
  case JSON.node(value)
    JSON.Node.Null -> puts("#{pad}null")
    JSON.Node.Bool(b) -> puts("#{pad}bool #{b}")
    JSON.Node.Int(n) -> puts("#{pad}int #{n - 1}")
    JSON.Node.BigInt(text) -> puts("#{pad}big #{text}")
    JSON.Node.Float(x) -> puts("#{pad}float #{x}")
    JSON.Node.String(s) -> puts("#{pad}string #{s}")
    JSON.Node.Array(items) ->
      puts("#{pad}array #{items.size}")
      items.each { |item| show(item, depth + 1) }
    JSON.Node.Object(members) ->
      puts("#{pad}object #{members.keys.join(",")}")
      members.each { |_, item| show(item, depth + 1) }
  end
end

def main() -> Void
  numbers = "[1, 3.0, 1e2, -0, 9223372036854775807, 9223372036854775808, -123456789012345678901234567890]"
  text = "{\"z\": #{numbers}, \"b\": {\"é\": null, \"a\": true, \"Z\": false}, \"a\": \"x\", \"\": {}}"
  show(JSON.parse(text).unwrap!, 0)
  built = JSON.object({"y": JSON.from(1.0), "x": JSON.array([JSON.from(2)])})
  show(built, 0)
  puts(JSON.from(5).node.inspect)
  puts(JSON.node(JSON.null()))
end
