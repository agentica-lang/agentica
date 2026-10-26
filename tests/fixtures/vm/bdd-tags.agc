import Tags from "std/bdd/tags"

def show(text: String, tags: List[String]) -> Void
  compiled = Tags.compile(text)
  if compiled.ok?
    puts("#{text.inspect} #{tags}: #{Tags.selects?(compiled.unwrap!, tags)}")
  else
    puts("#{text.inspect}: #{compiled.message}")
  end
end

def main() -> Void
  show("", [])
  show("@a", ["@a", "@b"])
  show("@a", ["@b"])
  show("@a", [])
  show("not @a", ["@b"])
  show("not @a", ["@a"])
  show("@a and @b", ["@a", "@b"])
  show("@a and @b", ["@a"])
  show("@a or @b", ["@b"])
  show("@a or @b", ["@c"])
  show("@a and not @b or @c", ["@a", "@b"])
  show("@a and not @b or @c", ["@a", "@c", "@b"])
  show("@a and not @b or @c", ["@a"])
  show("  @a \t or \n @b ", ["@b"])
  show("a", [])
  show("@", [])
  show("and", [])
  show("@a and", [])
  show("or @a", [])
  show("@a @b", [])
  show("@a and or @b", [])
  show("not not @a", ["@a"])
  show("not not not @a", ["@a"])
  show("@a#{String.from_code(160)}or#{String.from_code(8195)}@b", ["@b"])
  show("@a or not", [])
  show("(@a)", [])
  puts(Tags.filters?(Tags.compile("").unwrap!))
  puts(Tags.filters?(Tags.compile("@a").unwrap!))
end
