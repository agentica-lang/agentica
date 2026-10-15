def ints(field: String) -> List[Int]
  if field == "-"
    return []
  end
  return field.split(",").map do |text| text.to_i! end
end

def words(field: String) -> List[String]
  if field == "-"
    return []
  end
  return field.split(",")
end

def int_field(items: List[Int]) -> String
  if items.size == 0
    return "-"
  end
  texts = items.map do |n| n.to_s end
  return texts.join(",")
end

def word_field(items: List[String]) -> String
  if items.size == 0
    return "-"
  end
  return items.join(",")
end

# Walks the set with `for`, so the vectors also pin the loop order.
def looped_ints(s: Set[Int]) -> String
  items: List[Int] = []
  for n in s
    items = items.push(n)
  end
  return int_field(items)
end

def looped_words(s: Set[String]) -> String
  items: List[String] = []
  for w in s
    items = items.push(w)
  end
  return word_field(items)
end

def run_ints(op: String, a: String, b: String) -> String
  s = Set.new(ints(a))
  if op == "new"
    return looped_ints(s)
  elsif op == "size"
    return s.size.to_s
  elsif op == "empty"
    return s.empty?.to_s
  elsif op == "add"
    return int_field(s.add(b.to_i!).to_a)
  elsif op == "delete"
    return int_field(s.delete(b.to_i!).to_a)
  elsif op == "include"
    return s.include?(b.to_i!).to_s
  elsif op == "union"
    return int_field(s.union(Set.new(ints(b))).to_a)
  elsif op == "intersection"
    return int_field(s.intersection(Set.new(ints(b))).to_a)
  elsif op == "difference"
    return int_field(s.difference(Set.new(ints(b))).to_a)
  elsif op == "subset"
    return s.subset?(Set.new(ints(b))).to_s
  elsif op == "text"
    return s.to_s
  elsif op == "walk"
    for step in b.split(",")
      value = step.slice(1, step.length - 1).to_i!
      if step.at(0) == "+"
        s = s.add(value)
      else
        s = s.delete(value)
      end
    end
    return int_field(s.to_a)
  end
  return "unknown op " + op
end

def run_words(op: String, a: String, b: String) -> String
  s = Set.new(words(a))
  if op == "new"
    return looped_words(s)
  elsif op == "size"
    return s.size.to_s
  elsif op == "empty"
    return s.empty?.to_s
  elsif op == "add"
    return word_field(s.add(b).to_a)
  elsif op == "delete"
    return word_field(s.delete(b).to_a)
  elsif op == "include"
    return s.include?(b).to_s
  elsif op == "union"
    return word_field(s.union(Set.new(words(b))).to_a)
  elsif op == "intersection"
    return word_field(s.intersection(Set.new(words(b))).to_a)
  elsif op == "difference"
    return word_field(s.difference(Set.new(words(b))).to_a)
  elsif op == "subset"
    return s.subset?(Set.new(words(b))).to_s
  elsif op == "text"
    return s.to_s
  elsif op == "walk"
    for step in b.split(",")
      value = step.slice(1, step.length - 1)
      if step.at(0) == "+"
        s = s.add(value)
      else
        s = s.delete(value)
      end
    end
    return word_field(s.to_a)
  end
  return "unknown op " + op
end

def clip(text: String) -> String
  if text.length > 120
    return text.slice(0, 120)
  end
  return text
end

def check(line: String) -> Int
  f = line.split(";")
  got = ""
  if f[0] == "i"
    got = run_ints(f[1], f[2], f[3])
  else
    got = run_words(f[1], f[2], f[3])
  end
  if got == f[4]
    return 0
  end
  puts("mismatch: " + clip(line) + ": got " + clip(got))
  return 1
end

def main() -> Void
  IO.gets()
  count = 0
  failed = 0
  running = true
  while running
    case IO.gets()
      ok(line) ->
        failed += check(line)
        count += 1
      error(message) ->
        running = false
    end
  end
  if failed == 0
    puts("#{count} vectors ok")
  else
    puts("#{failed} of #{count} vectors failed")
  end
end
