"""The exhaustiveness of `case` (docs/grammar/06-semantics.md) against a model that enumerates every value.

Hypothesis builds small programs with one `case` over a type of a catalog: a plain enum, a recursive enum, generic
enums of one and two parameters, Optional and Result nested to depth 3, and Int payloads matched by literals. The arms
are random patterns (guarded ones and or-patterns of nested alternatives too), or a complete cover with one arm dropped
or one added. The model enumerates the values of the type (Int as 0, 1 and any other; the recursive enum to depth 5,
then one opaque deeper value) and says the case is exhaustive when the unguarded arms match each one. It also follows
the checker's syntactic rule for unreachable arms, which the program must agree with first. Each batch of programs is
one `--json check`.
"""
import tempfile
from importlib.util import find_spec
from pathlib import Path

from tests.agentica_test import SLOW, require
from tests.spec_support import check_many

require(find_spec("hypothesis") is not None, "hypothesis is required (poetry install --only test --no-root)")

from hypothesis import given, settings, strategies as st  # noqa: E402

DECLS = ("enum S\n  A\n  B\n  C\nend\n\nenum Tree\n  Leaf\n  Node(Tree)\nend\n\n"
         "enum Box[T]\n  Full(T)\n  Empty\nend\n\nenum Pair[A, B]\n  Both(A, B)\n  Left(A)\n  Neither\nend\n\n")
BATCH = 20
TREE_DEPTH = 5
OTHER = "other"
DEEP = "deep"

# The variants of each kind of type: (name, payload) where the payload lists the slot types by position.


def variants(t):
    kind = t[0]
    if kind == "S":
        return [("A", []), ("B", []), ("C", [])]
    if kind == "Tree":
        return [("Leaf", []), ("Node", [("Tree",)])]
    if kind == "Opt":
        return [("Some", [t[1]]), ("None", [])]
    if kind == "Res":
        return [("Ok", [t[1]]), ("Err", [("Error",)])]
    if kind == "Box":
        return [("Full", [t[1]]), ("Empty", [])]
    if kind == "Pair":
        return [("Both", [t[1], t[2]]), ("Left", [t[1]]), ("Neither", [])]
    return []


def type_text(t):
    kind = t[0]
    simple = {"Int": "Int", "S": "S", "Tree": "Tree"}
    if kind in simple:
        return simple[kind]
    if kind == "Opt":
        return "Optional[%s]" % type_text(t[1])
    if kind == "Res":
        return "Result[%s]" % type_text(t[1])
    if kind == "Box":
        return "Box[%s]" % type_text(t[1])
    return "Pair[%s, %s]" % (type_text(t[1]), type_text(t[2]))


def values(t, depth=0):
    """Every value of the type, as (variant, payload values), an Int, or the opaque values OTHER and DEEP."""
    kind = t[0]
    if kind == "Int":
        return [0, 1, OTHER]
    if kind == "Error":
        return [OTHER]
    if kind == "Tree" and depth >= TREE_DEPTH:
        return [DEEP]
    found = []
    for name, payload in variants(t):
        combos = [()]
        for slot in payload:
            combos = [c + (v,) for c in combos for v in values(slot, depth + 1 if kind == "Tree" else depth)]
        found.extend((name, combo) for combo in combos)
    return found


def matches(pattern, value):
    if pattern[0] in ("_", "bind"):
        return True
    if pattern[0] == "lit":
        return value == pattern[1]
    if not isinstance(value, tuple):
        return False
    _, name, slots = pattern
    return name == value[0] and all(matches(p, v) for p, v in zip(slots, value[1]))


def exhaustive(t, arms):
    covering = [alt for patterns, guarded in arms if not guarded for alt in patterns]
    return all(any(matches(p, v) for p in covering) for v in values(t))


def irrefutable(pattern):
    return pattern[0] == "var" and all(slot[0] in ("_", "bind") for slot in pattern[2])


def unreachable(t, arms):
    """The checker's rule: an arm after an unguarded catch-all or after the arms that cover every variant with names
    and `_`, and a pattern whose variant (or literal) an unguarded earlier pattern of that kind already covers."""
    names = [name for name, _ in variants(t)]
    covered, literals, wildcard = set(), set(), False
    for patterns, guarded in arms:
        seen_covered, seen_literals, seen_wildcard = set(covered), set(literals), wildcard
        for pattern in patterns:
            done = seen_wildcard or (names and all(n in seen_covered for n in names))
            if done:
                return True
            if pattern[0] in ("_", "bind"):
                seen_wildcard = True
            elif pattern[0] == "lit":
                if pattern[1] in seen_literals:
                    return True
                seen_literals.add(pattern[1])
            else:
                if pattern[1] in seen_covered:
                    return True
                if irrefutable(pattern):
                    seen_covered.add(pattern[1])
        if not guarded:
            covered, literals, wildcard = seen_covered, seen_literals, seen_wildcard
    return False


def render(pattern, t, binders):
    """The Agentica text of a pattern: a binder gets the next `_vN` name, or `_` in an or-pattern (binders None)."""
    kind = pattern[0]
    if kind == "_":
        return "_"
    if kind == "bind":
        if binders is None:
            return "_"
        binders.append(len(binders))
        return "_v%d" % len(binders)
    if kind == "lit":
        return str(pattern[1])
    _, name, slots = pattern
    payload = dict(variants(t))[name]
    inner = [render(p, s, binders) for p, s in zip(slots, payload)]
    if t[0] == "Opt":
        return "some(%s)" % inner[0] if name == "Some" else "none"
    if t[0] == "Res":
        return "ok(%s)" % inner[0] if name == "Ok" else "error(%s)" % inner[0]
    head = "%s.%s" % ({"S": "S", "Tree": "Tree", "Box": "Box", "Pair": "Pair"}[t[0]], name)
    return "%s(%s)" % (head, ", ".join(inner)) if inner else head


def program(t, arms):
    binders = []
    lines = []
    for index, (patterns, guarded) in enumerate(arms):
        several = len(patterns) > 1
        # A name is no pattern at the top of an arm: it is `_` there.
        text = ", ".join("_" if p[0] == "bind" else render(p, t, None if several else binders) for p in patterns)
        guard = " if %d > 2" % index if guarded else ""
        lines.append('    %s%s -> puts("%d")\n' % (text, guard, index))
    return "%sdef f(x: %s) -> Void\n  case x\n%s  end\nend\n\ndef main() -> Void\nend\n" % (
        DECLS, type_text(t), "".join(lines))


def leaf_types():
    return st.sampled_from([("Int",), ("S",), ("Tree",)])


def types(depth=3):
    if depth == 0:
        return leaf_types()
    inner = types(depth - 1)
    return st.one_of(
        leaf_types(),
        inner.map(lambda t: ("Opt", t)),
        inner.map(lambda t: ("Res", t)),
        inner.map(lambda t: ("Box", t)),
        st.tuples(inner, inner).map(lambda pair: ("Pair", pair[0], pair[1])),
    )


@st.composite
def patterns(draw, t, depth=0):
    """A pattern of the type; at the top (depth 0) mostly a variant, so most arms are reachable."""
    kind = t[0]
    choice = draw(st.integers(0, 7 if depth == 0 else 3))
    if kind == "Error" or choice == 0 or (kind == "Tree" and depth >= TREE_DEPTH - 1):
        return draw(st.sampled_from([("_",), ("bind",)]))
    if kind == "Int":
        return draw(st.sampled_from([("_",), ("bind",), ("lit", 0), ("lit", 1)]))
    name, payload = draw(st.sampled_from(variants(t)))
    return ("var", name, tuple([draw(patterns(slot, depth + 1)) for slot in payload]))


def complete(t, depth, draw):
    """A set of patterns that matches every value: `_`, or each variant with complete payload sets crossed."""
    if t[0] in ("Int", "Error") or depth >= 2 or draw(st.booleans()):
        return [("bind",)]
    found = []
    for name, payload in variants(t):
        combos = [()]
        for slot in payload:
            combos = [c + (p,) for c in combos for p in complete(slot, depth + 1, draw)][:6]
        found.extend(("var", name, combo) for combo in combos)
    return found


@st.composite
def cases(draw):
    t = draw(types())
    if draw(st.booleans()):
        cover = complete(t, 0, draw)
        arms = [([p], False) for p in cover]
        if draw(st.booleans()) and len(arms) > 1:
            del arms[draw(st.integers(0, len(arms) - 1))]
        else:
            arms.insert(draw(st.integers(0, len(arms))), ([draw(patterns(t))], draw(st.booleans())))
        return t, arms
    count = draw(st.integers(1, 8))
    # The arms of a random case drop the ones the checker calls unreachable, so most programs test the cover.
    arms = []
    for _ in range(count):
        several = draw(st.sampled_from([1, 1, 1, 1, 2, 3]))
        group = [draw(patterns(t)) for _ in range(several)]
        arm = (group, draw(st.integers(0, 4)) == 0)
        if not unreachable(t, arms + [arm]):
            arms.append(arm)
    return t, arms if arms else [([("_",)], False)]


def check_batch(batch):
    with tempfile.TemporaryDirectory() as folder:
        texts = [program(t, arms) for t, arms in batch]
        check = check_many(texts, Path(folder))
        for (t, arms), text in zip(batch, texts):
            found = check(text)
            code = found["code"] if found else None
            if unreachable(t, arms):
                assert code == "CHECK-UNREACHABLE-CASE-ARM", text
                continue
            wanted = None if exhaustive(t, arms) else "CHECK-NON-EXHAUSTIVE-CASE"
            assert code == wanted, "%s\nchecker: %s" % (text, found)


# A property runs in both tiers (tests/conftest.py): a few batches in the fast tier, many in the slow one.
@settings(max_examples=400 if SLOW else 80)
@given(st.lists(cases(), min_size=BATCH, max_size=BATCH))
def test_case_exhaustiveness_matches_the_model(batch):
    check_batch(batch)
