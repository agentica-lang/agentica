# The VM returns one shared object for the empty String, Set, List and Map and for each one-character ASCII String.
# Whatever a program builds on one gives a new value and leaves the shared one as it was, in every task.
struct Row
  name: String
  note: String
end

def build(label: String) -> String
  empty = "  ".trim
  letter = "xyz".at(1)
  both = empty + letter + label.slice(0, 0) + (label + "!").at(0)
  words = "#{label},,#{label}".split(",")
  return "#{both.inspect} #{words.inspect} #{empty.length} #{letter}"
end

def grow(seed: Int) -> String
  base: Set[Int] = Set.new([])
  held = base.add(seed).add(seed + 1)
  gone = held.delete(seed).delete(seed + 1)
  back = gone.add(seed * 2)
  return "#{base} #{held} #{gone} #{back}"
end

def main() -> Void
  # One-character Strings from at, slice, from_code, split, trim and case changes.
  hello = "hello"
  e = hello.at(1)
  e_slice = hello.slice(1, 1)
  e_code = String.from_code(101)
  e_split = hello.split("")[1]
  e_trim = "  e ".trim
  e_case = "E".downcase
  puts([e, e_slice, e_code, e_split, e_trim, e_case])
  puts([e == e_slice, e == e_code, e == e_split, e == e_trim, e == e_case])
  puts(e + e_slice + e_code)
  puts(e)
  puts("A".downcase + "b".upcase + "c".reverse + "Z".upcase)
  puts(String.from_code(0).code)
  puts(String.from_code(128512).length)
  puts("é".at(0).code)
  puts("a😀".at(1).length)

  # The empty String from slice, trim, join, replace, split, from_bytes, Result.message and a digit's text.
  nothing = hello.slice(2, 0)
  blank = " \t\n".trim
  joined = String.join(["", ""], "")
  erased = "abc".replace("abc", "")
  no_bytes = String.from_bytes("".bytes).unwrap!
  pieces = ",a,,b,".split(",")
  puts([nothing, blank, joined, erased, no_bytes].inspect)
  puts(pieces.inspect)
  puts(pieces.map do |p| p.length end)
  puts(nothing + "x" + blank + "y" + joined + erased + no_bytes)
  puts(nothing.inspect)
  puts(ok(5).message.inspect)
  puts((7).to_s + (3).to_s + "#{4}".at(0))
  puts(nothing == "")
  puts(nothing == blank)

  # Shared Strings as Map keys, Set elements, struct fields and JSON strings.
  counts: Map[String, Int] = {}
  for ch in "banana".split("")
    counts = counts.put(ch, counts.get(ch, 0) + 1)
  end
  puts(counts)
  puts(counts.put("", 9).get("", 0))
  letters = Set.new("banana".split(""))
  puts(letters)
  puts(letters.add("").add("a").size)
  row = Row(name: "a", note: "")
  puts(row)
  puts(row.with(note: "b"))
  puts(row)
  parsed = JSON.parse("{\"\": \"\", \"a\": [\"b\", \"\", \"cd\"]}").unwrap!
  puts(JSON.encode(parsed))
  decoded = JSON.decode("{\"name\": \"q\", \"note\": \"\"}", Row).unwrap!
  puts(decoded)
  puts(decoded.name == "q")

  # Empty Sets, Lists and Maps from every builtin that can return one, then built on.
  none_ints: List[Int] = []
  same: Set[Int] = Set.new(none_ints)
  puts(same)
  puts(same.add(1))
  puts(same)
  puts(Set.new([1]).delete(1))
  puts(Set.new([1, 2]).difference(Set.new([1, 2])))
  puts(Set.new([1]).intersection(Set.new([2])))
  puts(Set.new([1]).delete(1).add(5))
  puts(Set.new([1]).delete(1).empty?)
  puts(Set.new([1]).delete(1).to_a)
  puts(Set.new([1]).delete(1).union(Set.new([4, 5])))
  one_pair: Map[Int, Int] = {1: 1}
  puts(one_pair.delete(1))
  puts(one_pair.delete(1).put(2, 2))
  puts(one_pair.delete(1))
  puts(one_pair.delete(1).keys)
  items = [1, 2, 3]
  puts([items.take(0), items.drop(3), List.repeat(7, 0), (3..1).to_a])
  puts("".split(""))
  puts(items.take(0).push(1))
  puts(items.take(0))
  puts(items.filter do |x| x > 5 end)
  puts(items.map do |x| x + 1 end)
  puts(none_ints.map do |x| x + 1 end)
  puts(none_ints.reverse.push(4))
  puts([1].reverse)
  puts(none_ints.concat(items))

  # Tasks read and build on the same shared values.
  first = Task.spawn(&grow, 1)
  second = Task.spawn(&grow, 10)
  third = Task.spawn(&build, "p")
  fourth = Task.spawn(&build, "")
  puts(Task.await(first))
  puts(Task.await(second))
  puts(Task.await(third))
  puts(Task.await(fourth))
  puts(grow(3))
  puts(build("w"))

  # Nothing above changed the shared values.
  puts(hello.at(1).inspect + hello.slice(1, 1).inspect + "".inspect + same.size.to_s)
  puts(Set.new(none_ints))
  puts(Set.new(none_ints).add(8))
  puts(Set.new(none_ints))
end
