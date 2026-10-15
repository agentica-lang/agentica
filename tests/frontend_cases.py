"""Inputs that are a formula, shared by the front-end tests (tests/test_frontend_<stage>.py).

The Racket writers of the frozen comparisons (tests/frontend-<stage>-freeze.rkt) build the same inputs and record
their SHA-256 in the manifests; the tests here rebuild them and check the hash, so a drift of either side shows as an
input that differs, not as a front-end bug.
"""


def repeat(text, count):
    return text * count


def nested_chains(k, length):
    """k chains of `length` links, each inside the right operand of the first link of the next: the tree is k * length
    levels deep (7,200 for 8 times 900), where the parser only counts about 2 levels for each chain."""
    text = "x"
    for _ in range(k):
        text = "x + (" + text + ")" + repeat(" + x", length)
    return text


def checked_body(body):
    """A program of the checker and the lowering tests: a function f and a main that has the body."""
    return "def f(a: Int) -> Int\n  return a\nend\n\ndef main() -> Void\n  x = 1\n" + body + "end\n\n"


def check_deep_cases():
    """Trees around the nesting limit of the checker: 1000 levels of expressions and statements (check_state.agc)."""
    def bind(text):
        return checked_body("  y = " + text + "\n  puts(y)\n")

    return {
        "chain-900": bind("x" + repeat(" + x", 900)),
        "chain-997": bind("x" + repeat(" + x", 997)),
        "chain-998": bind("x" + repeat(" + x", 998)),
        "nested-chains": bind(nested_chains(8, 900)),
        "calls-900": bind(repeat("f(", 900) + "x" + repeat(")", 900)),
        "calls-998": bind(repeat("f(", 998) + "x" + repeat(")", 998)),
        "lists-990": bind(repeat("[", 990) + "x" + repeat("]", 990)),
        "negations": bind(repeat("-", 997) + "x"),
        "ifs": checked_body(repeat("  if x == 1\n", 450) + "  puts(x)\n" + repeat("  end\n", 450)),
        "ifs-and-chains": checked_body(
            repeat("  if x == 1\n", 300) + "  y = " + nested_chains(2, 500) + "\n" + repeat("  end\n", 300)),
        "chain-999": bind("x" + repeat(" + x", 999)),
    }


def lower_deep_cases():
    """Trees at the nesting limit of the checker (1,000 levels): lowering recurses on the tree, so these are the
    deepest inputs it can see."""
    def bind(text):
        return checked_body("  y = " + text + "\n  puts(y)\n")

    blocks = "".join("xs.map do |v%d| " % i for i in range(200))
    return {
        "chain-997": bind("x" + repeat(" + x", 997)),
        "calls-998": bind(repeat("f(", 998) + "x" + repeat(")", 998)),
        "lists-990": bind(repeat("[", 990) + "x" + repeat("]", 990)),
        "negations": bind(repeat("-", 997) + "x"),
        "parentheses": bind(repeat("(x + ", 490) + "x" + repeat(")", 490)),
        "interpolations": bind(repeat('"#{', 990) + "x" + repeat('}"', 990)),
        "ifs-990": checked_body(repeat("  if x == 1\n", 990) + "  puts(x)\n" + repeat("  end\n", 990)),
        "whiles-990": checked_body(repeat("  while x < 0\n", 990) + "  puts(x)\n" + repeat("  end\n", 990)),
        "blocks-200": checked_body("  xs = [1]\n  y = " + blocks + "v199" + repeat(" end", 200) + "\n"),
    }


def wide_span_programs():
    """Programs whose spans need the high bytes of a u32 (compiler/bytecode_bytes.agc, bytecode_spans.agc): one has its
    code after 65,600 blank lines, the other a string literal of 65,600 characters, so a column passes 65,535."""
    return {
        "lines": "\n" * 65600 + "def main() -> Void\n  puts(\"x\")\nend\n",
        "columns": "def main() -> Void\n  puts(\"" + "x" * 65600 + "\")\nend\n",
    }


STRUCT_AND_ENUM = (
    "struct Item\n  id: Int\n  name: String\n  score: Float\nend\n\n"
    "enum Shape\n  Circle(Float)\n  Rect(Float, Float)\nend\n\n")

# The placeholders are filled in order, as the format string of the Racket writer does.
CHECK_FUNCTION = """def f~a(xs: List[Int], label: String) -> Int
  total = 0
  items: List[Item] = []
  for x in xs
    if x % 2 == 0 and x > ~a
      total += x * ~a
    elsif x < 0
      total -= x
    else
      items = items.push(Item(id: x, name: "~a-" + label, score: 1.5))
    end
  end
  shape = Shape.Rect(1.0, 2.0)
  area = 0.0
  case shape
    Shape.Circle(r) -> area = r * r
    Shape.Rect(w, h) -> area = w * h
  end
  names = items.map do |it: Item| it.name.upcase end
  m: Map[String, Int] = {"a": 1, "b": ~a}
  total += names.size + m.size
  puts("f~a #{total} #{area} #{names.join(",")}")
  return total
end

"""

LOWER_FUNCTION = """def f~a(xs: List[Int], label: String) -> Int
  total = 0
  items: List[Item] = []
  for x in xs
    if x % 2 == 0 and x > ~a
      total += x * SCALE
    elsif x < 0
      total -= x
    else
      items = items.push(Item(id: x, name: "~a-" + label, score: 1.5))
    end
  end
  shape = Shape.Rect(1.0, 2.0)
  area = 0.0
  case shape
    Shape.Circle(r) -> area = r * r
    Shape.Rect(w, h) -> area = w * h
  end
  names = items.map do |it: Item| it.name.upcase end
  m: Map[String, Int] = {"a": 1, "b": ~a}
  total += names.size + m.size + LABELS.size
  puts("f~a #{total} #{area} #{names.join(",")}")
  return total
end

"""

MAIN_CALLING_F0 = "def main() -> Void\n  puts(f0([1, 2, 3], \"x\"))\nend\n"


def fill(template, values):
    parts = template.split("~a")
    assert len(parts) == len(values) + 1
    return "".join(part + str(value) for part, value in zip(parts, values + [""]))


def check_generated_program(count):
    """count functions that use structs, enums, lists, maps, case, blocks and interpolation."""
    functions = "".join(fill(CHECK_FUNCTION, [n, n % 7, n % 5 + 1, n, n, n]) for n in range(count))
    return STRUCT_AND_ENUM + functions + MAIN_CALLING_F0


def lower_generated_program(count):
    """count functions that use structs, enums, lists, maps, case, blocks, interpolation and a constant."""
    functions = "".join(fill(LOWER_FUNCTION, [n, n % 7, n, n % 5 + 1, n]) for n in range(count))
    return "LABELS = [\"a\", \"b\"]\nSCALE = 3\n\n" + STRUCT_AND_ENUM + functions + MAIN_CALLING_F0
