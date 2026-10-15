## Test driver of tests/test_std_toml.py: reads each file named on the command line, parses it
## with std/toml and prints one JSON line per file with the value in a tagged form.

import Toml from "std/toml"

def tag(kind: String, payload: Json) -> Json
  return JSON.object({"t": JSON.from(kind), "v": payload})
end

# Ints and floats are text (a float as its 64 bits), so Python can compare them exactly.
def tagged(value: Toml.Value) -> Json
  case value
    Toml.Value.Str(s) -> return tag("str", JSON.from(s))
    Toml.Value.Int(n) -> return tag("int", JSON.from(n.to_s))
    Toml.Value.Float(x) -> return tag("float", JSON.from(Float.to_bits(x).to_s))
    Toml.Value.Bool(b) -> return tag("bool", JSON.from(b))
    Toml.Value.DateTime(s) -> return tag("datetime", JSON.from(s))
    Toml.Value.Array(items) -> return tag("array", JSON.array(items.map do |item| tagged(item) end))
    Toml.Value.Table(entries) ->
      out: Map[String, Json] = {}
      for k in entries.keys
        out = out.put(k, tagged(entries[k]))
      end
      return tag("table", JSON.object(out))
  end
end

def report(path: String) -> Json
  text = File.read_text(path, 10000)
  if !text.ok?
    return JSON.object({"name": JSON.from(path), "ok": JSON.from(false), "error": JSON.from(text.message)})
  end
  parsed = Toml.parse(text.unwrap!)
  if !parsed.ok?
    return JSON.object({"name": JSON.from(path), "ok": JSON.from(false), "error": JSON.from(parsed.message)})
  end
  value = parsed.unwrap!
  encoded = Toml.encode(value)
  if !encoded.ok?
    return JSON.object({"name": JSON.from(path), "ok": JSON.from(true), "tagged": tagged(value), "encode_error": JSON.from(encoded.message)})
  end
  again = Toml.parse(encoded.unwrap!)
  if !again.ok?
    return JSON.object({"name": JSON.from(path), "ok": JSON.from(true), "tagged": tagged(value), "encoded": JSON.from(encoded.unwrap!), "reparse_error": JSON.from(again.message)})
  end
  return JSON.object({"name": JSON.from(path), "ok": JSON.from(true), "tagged": tagged(value), "encoded": JSON.from(encoded.unwrap!), "again": tagged(again.unwrap!)})
end

def main() -> Void
  for path in System.args()
    puts(JSON.encode(report(path)))
  end
end
