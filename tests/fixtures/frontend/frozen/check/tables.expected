## The method tables and help texts of the checker, as data. Edited by hand now; it was generated once from the tables
## of the former front end. tests/test_frontend_check.py compares it with a frozen copy (`tools/refreeze.py`).
## A key `Kind.name` pairs the kind of the receiver (String, List, ...) with a method name.

## The builtin module that holds the methods of each receiver kind.
export def method_modules() -> Map[String, String]
  return {
    "ATS": "ATS",
    "Bytes": "Bytes",
    "Channel": "Channel",
    "Codec": "JSON.Codec",
    "Float": "Float",
    "Int": "Int",
    "Json": "JSON",
    "Lazy": "Lazy",
    "List": "List",
    "Map": "Map",
    "Range": "Range",
    "Result": "Result",
    "Set": "Set",
    "String": "String",
  }
end

## The method names that are another builtin; `self` means the method returns the receiver.
export def method_aliases() -> Map[String, String]
  return {
    "ATS.length": "ATS.size",
    "Bytes.size": "Bytes.length",
    "Float.to_i": "Float.to_int",
    "Float.to_i!": "Float.to_int!",
    "Float.to_s": "String.from_float",
    "Int.to_f": "Float.from_int",
    "Int.to_s": "String.from_int",
    "Lazy.collect": "Lazy.map",
    "Lazy.detect": "Lazy.find",
    "Lazy.inject": "Lazy.reduce",
    "Lazy.select": "Lazy.filter",
    "List.collect": "List.map",
    "List.detect": "List.find",
    "List.inject": "List.reduce",
    "List.join": "String.join",
    "List.length": "List.size",
    "List.push": "List.append",
    "List.select": "List.filter",
    "Map.include?": "Map.has_key?",
    "Map.key?": "Map.has_key?",
    "Map.length": "Map.size",
    "Map.member?": "Map.has_key?",
    "Map.select": "Map.filter",
    "Range.length": "Range.size",
    "Range.member?": "Range.include?",
    "Set.length": "Set.size",
    "Set.member?": "Set.include?",
    "String.end_with?": "String.ends_with?",
    "String.include?": "String.contains?",
    "String.size": "String.length",
    "String.start_with?": "String.starts_with?",
    "String.strip": "String.trim",
    "String.to_f": "String.to_float",
    "String.to_f!": "String.to_float!",
    "String.to_i": "String.to_int",
    "String.to_i!": "String.to_int!",
    "String.to_s": "self",
  }
end

## The aliases of `method_aliases` that are a second Ruby name of a builtin whose own name is Ruby already: Ruby has
## both `length` and `size`, `map` and `collect`, so Agentica accepts both and its texts show the name of the builtin
## (`map`, `reduce`, `find`, `include?`, `size`). Every other alias is the Ruby name of a builtin that has a different
## name here (`strip` for `String.trim`, `select` for `List.filter`, `key?` for `Map.has_key?`), and the texts show it.
export def ruby_synonyms() -> List[String]
  return [
    "ATS.length", "Bytes.size", "Lazy.collect", "Lazy.detect", "Lazy.inject", "List.collect", "List.detect",
    "List.inject", "List.length", "Map.include?", "Map.length", "Map.member?", "Range.length", "Range.member?",
    "Set.length", "Set.member?", "String.size",
  ]
end

## The help for a name used as a function or type that another language has.
export def foreign_names() -> Map[String, String]
  return {
    "Array.new": "use a list literal with a type: xs: List[Int] = []",
    "Crypto.sha256": "use Digest.sha256(data), or Digest.sha256_hexdigest(data) for the hex text",
    "Enumerator.new": (
      "write the producer as a task that sends into a channel: ch: Channel[Int] = Channel.new(8), " +
      "Task.spawn(&produce, ch), then ch.recv(timeout_ms)"
    ),
    "Fiber.new": (
      "write the producer as a task that sends into a channel: ch: Channel[Int] = Channel.new(8), " +
      "Task.spawn(&produce, ch), then ch.recv(timeout_ms)"
    ),
    "Float.to_string": "use x.to_s",
    "Hash.new": "use a map literal with a type: m: Map[String, Int] = {}",
    "HttpWriter": (
      "a std/http handler returns its whole response: return ok(HttpResponse(status: 200, headers: [], body: text))"
    ),
    "Int.parse": "use s.to_i (a Result) or s.to_i!",
    "Int.to_float": "use n.to_f",
    "Int.to_string": "use n.to_s",
    "List.empty": "use a list literal with a type: xs: List[Int] = []",
    "List.new": "use a list literal with a type: xs: List[Int] = []",
    "Map.empty": "use a map literal with a type: m: Map[String, Int] = {}",
    "Map.new": "use a map literal with a type: m: Map[String, Int] = {}",
    "Mutex.new": "keep the state in one owner task that receives messages on a Channel, and send it requests",
    "Native.bytes_at": (
      "use Native.get_bytes(p, 0, length) for Native.bytes_at(p, length): its second argument is an offset"
    ),
    "Native.string_at": (
      "use Native.get_string(p, 0) for Native.string_at(p), and Native.get_string(p, 0, length) for " +
      "Native.string_at(p, length): its second argument is an offset"
    ),
    "None": "use nil",
    "Parallel.map": "use Task.map(items, limit, timeout_ms) do |x| ... end, where the block gives a Result",
    "Request": "a std/http handler takes an HttpRequest: def handle(request: HttpRequest) -> Result[HttpResponse]",
    "Set.empty": "write Set.new([]) where the type is known: seen: Set[Int] = Set.new([])",
    "SizedQueue.new": "use Channel.new(capacity): ch: Channel[Int] = Channel.new(8)",
    "Task.async": "use Task.spawn(&f, arg), and Task.await(task) for its result",
    "Task.async_stream": "use Task.map(items, limit, timeout_ms) do |x| ... end, where the block gives a Result",
    "Thread.new": "use Task.spawn do ... end (or Task.spawn(&f, arg)), and Task.await(task) for its result",
    "break": "break is a statement on its own line inside while or for",
    "continue": "write next, on its own line, to skip to the next iteration",
    "elif": "write elsif: if a ... elsif b ... else ... end",
    "elseif": "write elsif: if a ... elsif b ... else ... end",
    "float": "use n.to_f for an Int, s.to_f (a Result) or s.to_f! for a String",
    "input": "use gets, which returns Result[String]; gets! halts at the end of input",
    "inspect": "use x.inspect for the debug text, or IO.inspect(x) to print it and get x back",
    "int": "use s.to_i or f.to_i (both give a Result), or s.to_i! / f.to_i! to halt on failure",
    "len": "use x.length or x.size, which both work on a String, List, Map, Set and Range",
    "next": "next is a statement on its own line inside while or for",
    "nil?": "compare with nil: x == nil",
    "null": "use nil",
    "println": "use puts(x)",
    "range": "write a range: a..b includes b, a...b excludes it, as in for i in 0...n",
    "read_line": "use gets, which returns Result[String]; gets! halts at the end of input",
    "readline": "use gets, which returns Result[String]; gets! halts at the end of input",
    "str": "use x.to_s, or interpolation: \"\#{x}\"",
  }
end

## The Agentica methods that a foreign method name stands for.
export def foreign_methods() -> Map[String, List[String]]
  return {
    "contains": ["contains?", "include?"],
    "endswith": ["end_with?"],
    "include": ["include?"],
    "includes": ["contains?", "include?"],
    "includes?": ["contains?", "include?"],
    "len": ["size", "length"],
    "lower": ["downcase"],
    "ok!": ["unwrap!"],
    "startswith": ["start_with?"],
    "to_float": ["to_f", "to_float"],
    "to_int": ["to_i", "to_int"],
    "to_str": ["to_s"],
    "to_string": ["to_s"],
    "upper": ["upcase"],
    "value": ["unwrap!"],
    "value!": ["unwrap!"],
  }
end

## The help for a method another language has, by receiver kind.
export def foreign_kind_methods() -> Map[String, String]
  return {
    "Bytes.each_byte": "use b.each do |byte| ... end",
    "Bytes.getbyte": "use b.at(i), or b[i], which halts on a bad index",
    "Bytes.inject": "Bytes has no reduce; use b.to_a.reduce(0) do |acc, x| ... end",
    "Bytes.map": "Bytes has no map; use b.to_a.map do |x| ... end",
    "Bytes.select": "Bytes has no select; use b.to_a.select do |x| ... end",
    "Int.chr": "use String.from_code(n) for the character of a code point",
    "List.contains": "a List has no membership method; use xs.any? do |x| x == value end, or a Set with include?",
    "List.contains?": "a List has no membership method; use xs.any? do |x| x == value end, or a Set with include?",
    "List.count": "xs.size counts all elements; count those that pass a test with xs.select do |x| ... end.size",
    "List.include?": "a List has no membership method; use xs.any? do |x| x == value end, or a Set with include?",
    "List.includes": "a List has no membership method; use xs.any? do |x| x == value end, or a Set with include?",
    "List.includes?": "a List has no membership method; use xs.any? do |x| x == value end, or a Set with include?",
    "List.reject": "use xs.select do |x| !cond end to keep the elements that fail the test",
    "Map.contains": "use m.key?(key)",
    "Map.contains?": "use m.key?(key)",
    "Map.includes?": "use m.key?(key)",
    "Map.count": "use m.size",
    "Range.collect": "a range has no map; use (1..5).to_a.map do |x| ... end",
    "Range.detect": "a range has no find; use (1..5).to_a.find do |x| ... end",
    "Range.drop": "a range has no drop; use (1..5).to_a.drop(n)",
    "Range.find": "a range has no find; use (1..5).to_a.find do |x| ... end",
    "Range.inject": "a range has no reduce; use (1..5).to_a.reduce(0) do |acc, x| ... end",
    "Range.map": "a range has no map; use (1..5).to_a.map do |x| ... end",
    "Range.reject": "a range has no reject; use (1..5).to_a.select do |x| !cond end",
    "Range.select": "a range has no select; use (1..5).to_a.select do |x| ... end",
    "Range.sum": "a range has no sum; use (1..5).to_a.sum",
    "Range.take": "a range has no take; use (1..5).to_a.take(n)",
    "Set.contains": "use s.include?(x)",
    "Set.contains?": "use s.include?(x)",
    "Set.count": "use s.size",
    "Set.has?": "use s.include?(x)",
    "Set.includes": "use s.include?(x)",
    "Set.includes?": "use s.include?(x)",
    "Set.push": "sets are immutable; use s.add(x) and assign the result: s = s.add(x)",
    "Set.remove": "use s.delete(x) and assign the result: s = s.delete(x)",
    "String.blank?": "compare the trimmed length: s.strip.length == 0",
    "String.char_at": "use s.at(i) to read the character at a zero-based index",
    "String.chars": "s.split(\"\") gives the characters as a List[String]; s.at(i) reads one character",
    "String.chomp": "use s.strip to remove surrounding whitespace; IO.gets already drops the line ending",
    "String.chr": "use s.at(0) for the first character",
    "String.concat": "strings are immutable; join two strings with + and assign the result: a = a + b",
    "String.digit?": "test it with s.to_i (a Result): s.to_i.ok? is true for a whole number, s.to_f.ok? for a decimal",
    "String.count": "count a non-empty part with s.split(part).size - 1; s.length counts the characters",
    "String.drop": "use s.split(\"\").drop(n).join(\"\") for all but the first n characters; n may exceed the length",
    "String.each_char": "s.split(\"\") gives the characters as a List[String]; s.at(i) reads one character",
    "String.error?": "error? is not a String method; only a Result has ok? and message (!r.ok? tests for an error)",
    "String.gsub": "use s.replace(old, new)",
    "String.index": "use s.index_of(part), which gives a Result[Int]",
    "String.is_numeric": (
      "test it with s.to_i (a Result): s.to_i.ok? is true for a whole number, s.to_f.ok? for a decimal"
    ),
    "String.isdigit": (
      "test it with s.to_i (a Result): s.to_i.ok? is true for a whole number, s.to_f.ok? for a decimal"
    ),
    "String.lstrip": "use s.strip, which trims both ends",
    "String.match": (
      "there are no regular expressions; use s.include?(part), s.start_with?(part), s.end_with?(part) or " +
      "s.index_of(part)"
    ),
    "String.match?": (
      "there are no regular expressions; use s.include?(part), s.start_with?(part), s.end_with?(part) or " +
      "s.index_of(part)"
    ),
    "String.matches?": (
      "there are no regular expressions; use s.include?(part), s.start_with?(part), s.end_with?(part) or " +
      "s.index_of(part)"
    ),
    "String.numeric?": (
      "test it with s.to_i (a Result): s.to_i.ok? is true for a whole number, s.to_f.ok? for a decimal"
    ),
    "String.ord": "use s.code for the code point of a one-character string",
    "String.rstrip": "use s.strip, which trims both ends",
    "String.scan": (
      "there are no regular expressions; use s.include?(part), s.start_with?(part), s.end_with?(part) or " +
      "s.index_of(part)"
    ),
    "String.sub": "use s.replace(old, new)",
    "String.substr": "use s.slice(start, length) for a part of the text; length is end - start",
    "String.substring": "use s.slice(start, length) for a part of the text; length is end - start",
    "String.take": "use s.split(\"\").take(n).join(\"\") for the first n characters; n may exceed the length",
    "String.to_a": "s.split(\"\") gives the characters as a List[String]; s.at(i) reads one character",
    "String.to_s": "a String is already text; s.to_s gives the same string",
  }
end
