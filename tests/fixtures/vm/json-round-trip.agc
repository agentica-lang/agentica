def show(text: String) -> Void
  case JSON.parse(text)
    ok(j) ->
      puts(j)
      puts("#{JSON.encode(j)} #{j.inspect}")
    error(m) -> puts(m)
  end
end

def main() -> Void
  show("  {\"b\": [1, [2, [3, []]], {}], \"a\": {\"z\": null, \"y\": [true, false]}, \"b\": \"last\"}\r\n")
  show("[\"\\\"\\\\\\/\\b\\f\\n\\r\\t\", \"\\u0000\\u0001\\u001f\\u007f\", \"caf\\u00e9 \\u2028\"]")
  show("[\"\\ud83d\\ude00\", \"\\uD834\\uDD1E\", \"raw é 😀 ✓\"]")
  show("{\"é\": 1, \"Z\": 2, \"a\": 3, \"\": 4, \"a b\": 5, \"\\u0000\": 6}")
  show("[0, -5, 12.5, 1E2, 1e-7, 1e21, 123456789.123456789, 0.1]")
  show("\"" + String.from_code(127) + "\"")
  show("\"just a string\"")
  show("null")
  values = Result.unwrap!(JSON.parse("[1, \"two\", [3]]"))
  puts(JSON.list(values))
  puts("#{JSON.list(values).unwrap_or([JSON.null()])}")
end
