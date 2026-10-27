def count(hits: ATS[String, Int]) -> Int
  hits.put("home", 1)
  hits.put_new("away", 2)
  hits.add("home", 3)
  hits.delete("away")
  if hits.has_key?("home")
    puts(hits.keys.join(","))
  end

  copy: Map[String, Int] = hits.to_map
  return hits.size + copy.size + ATS.get(hits, "home").unwrap_or(0)
end

def main() -> Void
  hits: ATS[String, Int] = ATS.new()
  puts(count(hits))
end
