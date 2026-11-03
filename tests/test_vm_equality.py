"""== and != on structs, lists, maps, sets, Results, Optionals and enums on the VM, against Python's own == as the
independent peer: random pairs of nested values (equal copies, near copies and unrelated values, with map keys and set
elements written in the other order on the right) give the same answers; values 100,000 levels deep compare without a
C or VM stack overflow.
"""
import random

from tests.agentica_test import compile_text, run_vm, vm_environment

TYPES = """\
enum Val
  I(Int)
  F(Float)
  S(String)
  L(List[Val])
  M(Map[String, Val])
  P(Pair)
  T(Set[String])
  R(Result[Val])
  O(Optional[Val])
  N
end

struct Pair
  left: Val
  right: Val
end

"""

# A Python value is a tuple whose first item names the variant, so Python's == compares the variant first and then
# the payload: a tuple in order (List, Pair), a dict or a frozenset in any order (Map, Set), as the language rule says.
# A Result is ("ok", v) or ("error", message); an Optional is None or the value.
LEAVES = [("I", 0), ("I", 1), ("I", -7), ("F", 0.0), ("F", -0.0), ("F", 1.5), ("S", ""), ("S", "a"), ("S", "é"),
          ("N",)]


def value(rng, depth):
    if depth == 0 or rng.random() < 0.3:
        return rng.choice(LEAVES)
    kind = rng.choice("LMPTRO")
    if kind == "T":
        return ("T", frozenset(rng.choice("abcd") for _ in range(rng.randint(1, 3))))
    if kind == "R":
        if rng.random() < 0.3:
            return ("R", ("error", rng.choice(["x", "y"])))
        return ("R", ("ok", value(rng, depth - 1)))
    if kind == "O":
        return ("O", None if rng.random() < 0.3 else value(rng, depth - 1))
    if kind == "L":
        return ("L", tuple(value(rng, depth - 1) for _ in range(rng.randint(0, 3))))
    if kind == "M":
        return ("M", {rng.choice("abc"): value(rng, depth - 1) for _ in range(rng.randint(0, 3))})
    return ("P", (value(rng, depth - 1), value(rng, depth - 1)))


def near(rng, v):
    """A copy of v with at most one leaf changed somewhere inside, so the pair is often equal."""
    if v[0] == "L" and v[1] and rng.random() < 0.8:
        items = list(v[1])
        k = rng.randrange(len(items))
        items[k] = near(rng, items[k])
        return ("L", tuple(items))
    if v[0] == "M" and v[1] and rng.random() < 0.8:
        items = dict(v[1])
        key = rng.choice(sorted(items))
        items[key] = near(rng, items[key])
        return ("M", dict(reversed(list(items.items()))))
    if v[0] == "R" and v[1][0] == "ok" and rng.random() < 0.8:
        return ("R", ("ok", near(rng, v[1][1])))
    if v[0] == "O" and v[1] is not None and rng.random() < 0.8:
        return ("O", near(rng, v[1]))
    if v[0] == "P" and rng.random() < 0.8:
        left, right = v[1]
        return ("P", (near(rng, left), right)) if rng.random() < 0.5 else ("P", (left, near(rng, right)))
    return v if rng.random() < 0.5 else rng.choice(LEAVES)


def text(v, flip):
    """The Agentica literal of v; flip writes map keys and set elements in the other order."""
    kind = v[0]
    if kind == "I":
        return "Val.I(%d)" % v[1]
    if kind == "F":
        return "Val.F(%s)" % ("-0.0" if str(v[1]) == "-0.0" else repr(v[1]))
    if kind == "S":
        return 'Val.S("%s")' % v[1]
    if kind == "N":
        return "Val.N"
    if kind == "L":
        return "Val.L([%s])" % ", ".join(text(item, flip) for item in v[1])
    if kind == "M":
        pairs = sorted(v[1].items(), reverse=flip)
        return "Val.M({%s})" % ", ".join('"%s": %s' % (key, text(item, flip)) for key, item in pairs)
    if kind == "T":
        return "Val.T(Set.new([%s]))" % ", ".join('"%s"' % item for item in sorted(v[1], reverse=flip))
    if kind == "R":
        if v[1][0] == "error":
            return 'Val.R(error("%s"))' % v[1][1]
        return "Val.R(ok(%s))" % text(v[1][1], flip)
    if kind == "O":
        return "Val.O(none)" if v[1] is None else "Val.O(some(%s))" % text(v[1], flip)
    return "Val.P(Pair(left: %s, right: %s))" % (text(v[1][0], flip), text(v[1][1], flip))


def test_random_pairs_compare_as_python_does(tmp_path):
    rng = random.Random(978)
    pairs = []
    for _ in range(300):
        a = value(rng, 4)
        pairs.append((a, near(rng, a) if rng.random() < 0.7 else value(rng, 4)))
    lines = []
    for a, b in pairs:
        lines.append("  a = %s\n  b = %s\n  puts(\"#{a == b} #{a != b}\")" % (text(a, False), text(b, True)))
    program = TYPES + "def main() -> Void\n" + "\n".join(lines) + "\nend\n"
    vm = run_vm(compile_text(program, "equality_pairs", tmp_path), env=vm_environment())
    assert vm.code == 0, vm.stderr
    expected = ["%s %s" % (str(a == b).lower(), str(a != b).lower()) for a, b in pairs]
    assert vm.stdout.splitlines() == expected
    assert 60 < expected.count("true false") < 240


DEEP = """\
enum Tree
  Leaf(Int)
  Branch(List[Tree])
end

struct Link
  value: Int
  next: List[Link]
end

def tree(depth: Int, leaf: Int) -> Tree
  t = Tree.Leaf(leaf)
  i = 0
  while i < depth
    t = Tree.Branch([t])
    i += 1
  end

  return t
end

def chain(depth: Int, last: Int) -> Link
  link = Link(value: last, next: [])
  i = 0
  while i < depth
    link = Link(value: i, next: [link])
    i += 1
  end

  return link
end

def main() -> Void
  depth = 100000
  t = tree(depth, 1)
  puts("#{t == tree(depth, 1)} #{t == tree(depth, 2)} #{t != tree(depth - 1, 1)}")
  puts("#{chain(depth, 1) == chain(depth, 1)} #{chain(depth, 1) == chain(depth, 2)}")
end
"""


def test_values_a_hundred_thousand_levels_deep_compare(tmp_path):
    vm = run_vm(compile_text(DEEP, "equality_deep", tmp_path), env=vm_environment())
    assert vm.code == 0, vm.stderr
    assert vm.stdout.splitlines() == ["true false true", "true false"]
