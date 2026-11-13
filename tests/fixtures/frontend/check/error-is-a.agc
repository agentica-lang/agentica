def insert(name: String) -> Result[Int]
  return error("unique failed", kind: "db.constraint", code: 19, details: {"name": name}) if name == "taken"

  ok(name.size)
end

def main() -> Void
  case insert("taken")
    ok(id) -> puts(id)
    error(e) if e.is_a?("db") -> puts(e.kind_of?("db.constraint"))
    error(e) -> puts(e)
  end
end
