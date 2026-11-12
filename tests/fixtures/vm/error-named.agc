# error(...) with named arguments builds an Error with those fields (#671): code and cause are stored as some(...),
# the fields left out keep their defaults, and the location is the place of the call, as for error("text").

def insert(name: String) -> Result[Int]
  return error("unique failed", kind: "db.constraint", code: 19) if name == "taken"

  ok(name.size)
end

def load(name: String) -> Result[Int]
  case insert(name)
    ok(id) -> ok(id)
    error(e) -> Result.Err("cannot load #{name}", details: {"name": name}, cause: e, kind: "config")
  end
end

def show(label: String, e: Error) -> Void
  puts("#{label}: kind=#{e.kind} message=#{e.message} code=#{e.code} details=#{e.details} at #{e.location}")
end

def main() -> Void
  case insert("taken")
    ok(id) -> puts(id)
    error(e) ->
      show("insert", e)
      puts(e.inspect)
  end

  case load("taken")
    ok(id) -> puts(id)
    error(e) ->
      show("load", e)
      case e.cause
        some(inner) -> show("cause", inner)
        none -> puts("no cause")
      end

      puts(e)
  end

  # A computed kind is kept as it is; only a literal is checked.
  kind = "Any Text"
  computed: Result[Int] = error("x", kind: kind)
  case computed
    ok(n) -> puts(n)
    error(e) -> show("computed", e)
  end

  # Equality leaves the location out, so the same fields made elsewhere are equal.
  same: Result[Int] = error("unique failed", kind: "db.constraint", code: 19)
  puts(insert("taken") == same)
  plain: Result[Int] = error("unique failed")
  puts(insert("taken") == plain)
  puts(load("ok"))
end
