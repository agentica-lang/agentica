## Test program of tests/test_std_toml.py: one case of std/toml per command-line argument.

import Toml from "std/toml"

struct Limits
  cpu: Int
end

struct Config
  name: String
  port: Int
  ratio: Float
  debug: Bool
  tags: List[String]
  since: String
  limits: Limits
end

def table(entries: Map[String, Toml.Value]) -> Toml.Value
  return Toml.Value.Table(entries)
end

def unwrap_value(text: String) -> Toml.Value
  return Result.unwrap!(Toml.parse(text))
end

# A canonical text of a value, to compare two values (floats by their bits).
def show(value: Toml.Value) -> String
  case value
    Toml.Value.Str(s) -> return "str(" + JSON.encode(s) + ")"
    Toml.Value.Int(n) -> return "int(" + n.to_s + ")"
    Toml.Value.Float(x) -> return "float(" + Float.to_bits(x).to_s + ")"
    Toml.Value.Bool(b) -> return "bool(" + b.to_s + ")"
    Toml.Value.DateTime(s) -> return "datetime(" + s + ")"
    Toml.Value.Array(items) -> return "[" + items.map do |item| show(item) end.join(",") + "]"
    Toml.Value.Table(entries) -> return "{" + entries.keys.map do |k| JSON.encode(k) + ":" + show(entries[k]) end.join(",") + "}"
  end
end

def brief(result: Result[Toml.Value]) -> String
  if !result.ok?
    return result.message
  end
  case result.unwrap!
    Toml.Value.Str(s) -> return "str " + s
    Toml.Value.Int(n) -> return "int " + n.to_s
    Toml.Value.Table(entries) -> return "table " + entries.size.to_s
    Toml.Value.Array(items) -> return "array " + items.size.to_s
    _ -> return "other"
  end
end

def flat(text: String) -> String
  return text.replace("\n", "<NL>")
end

def order_case() -> Void
  rows: Map[String, Toml.Value] = {}
  sub: Map[String, Toml.Value] = {"z": Toml.Value.Int(1)}
  one: Map[String, Toml.Value] = {"n": Toml.Value.Int(1)}
  two: Map[String, Toml.Value] = {"n": Toml.Value.Int(2)}
  root: Map[String, Toml.Value] = {}
  root = root.put("sub", table(sub))
  root = root.put("rows", Toml.Value.Array([table(one), table(two)]))
  root = root.put("title", Toml.Value.Str("x"))
  root = root.put("flag", Toml.Value.Bool(true))
  puts(flat(Result.unwrap!(Toml.encode(table(root)))))
end

def quoting_case() -> Void
  root: Map[String, Toml.Value] = {}
  weird = "tab" + String.from_code(9) + "here \"q\" back\\slash " + String.from_code(1) + " " + String.from_code(127) + " nl" + String.from_code(10) + " " + String.from_code(233) + " " + String.from_code(128512)
  root = root.put("a b", Toml.Value.Int(1))
  root = root.put("", Toml.Value.Int(2))
  root = root.put("dot.key", Toml.Value.Int(3))
  root = root.put("plain-key_1", Toml.Value.Int(4))
  root = root.put("s", Toml.Value.Str(weird))
  root = root.put("inf", Toml.Value.Float(Float.from_bits(9218868437227405312)))
  root = root.put("neg", Toml.Value.Float(Float.from_bits(-4503599627370496)))
  root = root.put("nothing", Toml.Value.Float(Float.from_bits(9221120237041090560)))
  inner: Map[String, Toml.Value] = {"k": Toml.Value.Str("v")}
  root = root.put("[quoted.tbl]", table(inner))
  encoded = Result.unwrap!(Toml.encode(table(root)))
  puts(flat(encoded))
  back = unwrap_value(encoded)
  if show(back) == show(table(root))
    puts("same")
  else
    puts("different: " + show(back))
  end
end

def encode_errors_case() -> Void
  bad = Toml.encode(Toml.Value.Int(1))
  puts("root: " + bad.message)
  entries: Map[String, Toml.Value] = {"when": Toml.Value.DateTime("yesterday")}
  puts("datetime: " + Toml.encode(table(entries)).message)
  deep: Map[String, Toml.Value] = {"list": Toml.Value.Array([Toml.Value.DateTime("1979-02-30")])}
  puts("nested datetime: " + Toml.encode(table(deep)).message)
  fine: Map[String, Toml.Value] = {"when": Toml.Value.DateTime("1979-05-27 07:32:00Z")}
  if Toml.encode(table(fine)).ok?
    puts("ok datetime: ok")
  end
end

def to_json_case() -> Void
  doc = unwrap_value("name = \"demo\"\nport = 8080\nratio = 0.5\ndebug = true\ntags = [\"a\", \"b\"]\nsince = 1979-05-27T07:32:00Z\n[limits]\ncpu = 4\n")
  config = Result.unwrap!(JSON.decode(JSON.encode(Result.unwrap!(Toml.to_json(doc))), Config))
  puts("name=" + config.name)
  puts("port=" + config.port.to_s)
  puts("ratio=" + config.ratio.to_s)
  puts("debug=" + config.debug.to_s)
  puts("tags=" + config.tags.join(","))
  puts("since=" + config.since)
  puts("limits.cpu=" + config.limits.cpu.to_s)
  floaty = unwrap_value("name = \"demo\"\nport = 8080.0\nratio = 0.5\ndebug = true\ntags = []\nsince = \"x\"\n[limits]\ncpu = 4\n")
  as_int = JSON.decode(JSON.encode(Result.unwrap!(Toml.to_json(floaty))), Config)
  if as_int.ok?
    puts("float as int: accepted")
  else
    puts("float as int: error")
  end
  puts("inf: " + Toml.to_json(unwrap_value("x = inf\n")).message)
  puts("nan inside: " + Toml.to_json(unwrap_value("x = [1, { y = nan }]\n")).message)
end

def json_kinds_case() -> Void
  doc = unwrap_value("f = 1.0\ni = 1\ne = 1e20\nz = -0.0\n")
  puts(JSON.encode(Result.unwrap!(Toml.to_json(doc))))
end

def get_case() -> Void
  doc = unwrap_value("[package]\nname = \"demo\"\nversion = \"1\"\n[[bin]]\npath = \"a\"\n[[bin]]\npath = \"b\"\n")
  puts("package.name: " + brief(Toml.get(doc, "package.name")))
  puts("bin.1.path: " + brief(Toml.get(doc, "bin.1.path")))
  puts("package: " + brief(Toml.get(doc, "package")))
  puts("missing: " + brief(Toml.get(doc, "package.nope")))
  puts("bad index: " + brief(Toml.get(doc, "bin.7")))
  puts("into scalar: " + brief(Toml.get(doc, "package.name.x")))
end

def round_trip_case() -> Void
  text = "top = 1\n[a]\nx = [[1, 2], [\"s\"], [{ k = 1 }, { k = 2 }]]\n[a.b]\ny = 2.5\n[[a.list]]\nn = 1\n[[a.list.sub]]\nm = 1\n[[a.list]]\nn = 2\n[empty]\n[\"k e y\".\"q.r\"]\nv = 'it is'\nlit = \"caf\\u00e9 \\U0001F600\"\nz = [ ]\n[[arr]]\n[[arr]]\nt = { a = { b = [] } }\n"
  first = unwrap_value(text)
  second = unwrap_value(Result.unwrap!(Toml.encode(first)))
  if show(first) == show(second)
    puts("same")
  else
    puts("different")
    puts(show(first))
    puts(show(second))
  end
end

def main() -> Void
  args = System.args()
  name = args[0]
  if name == "order"
    order_case()
  elsif name == "quoting"
    quoting_case()
  elsif name == "encode_errors"
    encode_errors_case()
  elsif name == "to_json"
    to_json_case()
  elsif name == "json_kinds"
    json_kinds_case()
  elsif name == "get"
    get_case()
  elsif name == "round_trip"
    round_trip_case()
  end
end
