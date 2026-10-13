def canonical(text: String) -> String
  return JSON.encode(JSON.parse(text).unwrap!)
end

def same(a: String, b: String) -> Void
  puts("#{canonical(a) == canonical(b)} #{a} #{b}")
end

def main() -> Void
  puts(canonical("{\"b\": 1, \"a\": 2, \"c\": 3}"))
  puts(canonical("{\"a\": 1, \"b\": 2, \"a\": 3}"))
  puts(canonical("{\"a\": {\"z\": [3, 1, {\"y\": 1, \"x\": 2}], \"m\": null}, \"B\": true, \"\": false}"))
  puts(canonical("{\"é\": 1, \"z\": 2, \"e\": 3, \"ab\": 4, \"a\": 5}"))
  puts(canonical("{\"k\": {\"b\": 1}, \"k\": {\"d\": 2, \"c\": 1}}"))
  puts(canonical(" [ 1 , 1.0 , 1e2 , \"\\u0041\" ] "))
  same("{\"a\": 1, \"b\": [1, 2]}", "{\"b\":[1,2],\"a\":1}")
  same("{\"a\": 1, \"a\": 2}", "{\"a\": 2}")
  same("[1, 2]", "[2, 1]")
  same("{\"a\": 1}", "{\"a\": 1.0}")
  same("1", "1.0")
end
