# == and != on JSON.Value: objects compare by key in any order, at any depth; arrays in order; numbers by the text
# JSON writes, so 1 and 1.0 differ.
struct Event
  name: String
  data: JSON.Value
end

def parsed(text: String) -> JSON.Value = JSON.parse(text).unwrap!

def same(a: String, b: String) -> Void
  left = parsed(a)
  right = parsed(b)
  puts("#{left == right} #{left != right} #{a} #{b}")
end

def main() -> Void
  same("{\"a\": 1, \"b\": 2}", "{\"b\": 2, \"a\": 1}")
  nested = "{\"x\": {\"p\": [1, {\"q\": null, \"r\": true}], \"s\": \"t\"}}"
  same(nested, "{\"x\": {\"s\": \"t\", \"p\": [1, {\"r\": true, \"q\": null}]}}")
  same("{\"a\": 1, \"a\": 2}", "{\"a\": 2}")
  same("[1, 2]", "[2, 1]")
  same("{\"a\": 1}", "{\"a\": 1, \"b\": 1}")
  same("{\"a\": {\"b\": 1}}", "{\"a\": {\"b\": 2}}")
  same("{\"a\": 1}", "{\"a\": 1.0}")
  same("\"1\"", "1")
  same("null", "null")

  built = JSON.object({"name": JSON.from("ada"), "tags": JSON.from(["x", "y"])})
  puts(built == parsed("{\"tags\": [\"x\", \"y\"], \"name\": \"ada\"}"))
  puts([parsed("{\"a\": 1, \"b\": 2}")].include?(parsed("{\"b\": 2, \"a\": 1}")))
  one = Event(name: "e", data: parsed("{\"k\": 1, \"v\": [2]}"))
  puts(one == Event(name: "e", data: parsed("{\"v\": [2], \"k\": 1}")))
  puts(one == one.with(data: parsed("{\"v\": [3], \"k\": 1}")))
end
