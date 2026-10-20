"""The compiler prelude: methods written in Agentica in stdlib/prelude/ (25.6).

Three checks cover the table and source files, avoid quadratic builtin use, and
compare prelude behavior against Python peers on random lists and strings.
"""
import itertools
import json
import math
import random
import re

from tests.agentica_test import ROOT, cli, run

PRELUDE = ROOT / "stdlib" / "prelude"
TABLE = (ROOT / "compiler" / "prelude_data.agc").read_text(encoding="utf-8")
SLOW_IN_A_LOOP = re.compile(r"\.(concat|take|drop|reverse|sort|sort_by|keys|values|delete)\b")
LOOP_START = re.compile(r"^(\s*)(for|while)\b")


def table_functions() -> set[tuple[str, str]]:
    """Return (file stem, function name) pairs from compiler/prelude_data.agc rows."""
    found = set()
    row = re.compile(
        r'Model\.PreludeRow\((?:(?!Model\.PreludeRow\().)*?'
        r'module: "([a-z]+)".*?bodies: (\{[^}]*\})',
        flags=re.DOTALL,
    )
    for module, bodies in row.findall(TABLE):
        for name in re.findall(r': "([a-z_]+)"', bodies):
            found.add((module, name))
    return found


def declared_functions():
    """Return (file stem, function name) pairs from stdlib/prelude/ source files."""
    found = set()
    for path in sorted(PRELUDE.glob("*.agc")):
        for name in re.findall(r"^def ([a-z_]+)\(", path.read_text(encoding="utf-8"), flags=re.MULTILINE):
            found.add((path.stem, name))
    return found


def slow_calls(text):
    """List O(n) builtin calls inside loops or blocks, with source line numbers."""
    found = []
    inside = None
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if inside is not None and indent <= inside:
            inside = None
        start = LOOP_START.match(line)
        if inside is None and start:
            inside = len(start.group(1))
            continue
        in_block = re.search(r"\bdo\b", line) is not None
        if (inside is not None or in_block) and SLOW_IN_A_LOOP.search(line):
            found.append("%d: %s" % (number, stripped))
    return found


def literal(value):
    if isinstance(value, str):
        return '"%s"' % value
    if isinstance(value, float):
        return "nan" if value != value else repr(value)
    return str(value)


def show(value):
    """Format values as Agentica's to_s does for the cases used by these peers."""
    if isinstance(value, str):
        return '"%s"' % value
    if isinstance(value, float):
        return "+nan.0" if value != value else repr(value)
    if isinstance(value, dict):
        return "{" + ", ".join("%s: %s" % (show(key), show(item)) for key, item in value.items()) + "}"
    if isinstance(value, list):
        return "[" + ", ".join(show(item) for item in value) + "]"
    if isinstance(value, tuple):
        return ("ok(%s)" % show(value[1])) if value[0] == "ok" else 'error("%s")' % value[1]
    return str(value)


def pick(keys, wins):
    """Select the first index that wins; NaN wins only when every key is NaN."""
    if not keys:
        return ("error", "the list is empty")
    best = 0
    for index in range(1, len(keys)):
        key = keys[index]
        if key == key and (keys[best] != keys[best] or wins(key, keys[best])):
            best = index
    return ("ok", best)


def peer_lines(numbers, words, floats, names):
    """Compute the output of peer_program() independently with plain Python."""
    lines = []
    found = next((n for n in numbers if n % 5 == 0), None)
    lines.append(show(("ok", found) if found is not None else ("error", "not found")))
    lines.append(show([x for n in numbers for x in (n, -n)]))
    lines.append(show([[n for n in numbers if n % 2 == 0], [n for n in numbers if n % 2 != 0]]))
    prefix = 0
    while prefix < len(numbers) and numbers[prefix] < 5:
        prefix += 1
    lines.append(show(numbers[:prefix]))
    lines.append(show(numbers[prefix:]))
    for size in (1, 3):
        lines.append(show([numbers[at:at + size] for at in range(0, len(numbers), size)]))
    groups = {}
    # Agentica's % truncates toward zero, as in C; Python's % would give -5 % 3 == 1.
    for number in numbers:
        groups.setdefault(int(math.fmod(number, 3)), []).append(number)
    lines.append(show(groups))
    counts = {}
    for word in words:
        counts[word] = counts.get(word, 0) + 1
    lines.append(show(counts))
    lines.append(show(list(dict.fromkeys(words))))
    lines.append(show(sum(numbers)))
    total = 0.0
    for number in floats:
        total += number
    lines.append(show(total))
    # Python's string order is Unicode code-point order, as are compare and sort.
    for keys in (numbers, floats, names):
        lines.append(show(pick(keys, lambda a, b: a < b)))
        lines.append(show(pick(keys, lambda a, b: a > b)))
    return lines


def peer_program(numbers, words, floats, names):
    """Build one Agentica program whose output is checked against peer_lines()."""
    minmax = "\n".join(
        "  puts((0...%s.size).to_a.%s do |i| %s[i] end.to_s)" % (name, method, name)
        for name in ("numbers", "floats", "names")
        for method in ("min_by", "max_by")
    )
    return """\
def main() -> Void
  nan = Float.from_bits(9221120237041090560)
  numbers: List[Int] = [{numbers}]
  words: List[String] = [{words}]
  floats: List[Float] = [{floats}]
  names: List[String] = [{names}]
  puts(numbers.find do |n| n % 5 == 0 end.to_s)
  puts(numbers.flat_map do |n| [n, -n] end.to_s)
  puts(numbers.partition do |n| n % 2 == 0 end.to_s)
  puts(numbers.take_while do |n| n < 5 end.to_s)
  puts(numbers.drop_while do |n| n < 5 end.to_s)
  puts(numbers.each_slice(1).to_s)
  puts(numbers.each_slice(3).to_s)
  puts(numbers.group_by do |n| n % 3 end.to_s)
  puts(words.tally.to_s)
  puts(words.uniq.to_s)
  puts(numbers.sum.to_s)
  puts(floats.sum.to_s)
{minmax}
end
""".format(
        numbers=", ".join(map(literal, numbers)),
        words=", ".join(map(literal, words)),
        floats=", ".join(map(literal, floats)),
        names=", ".join(map(literal, names)),
        minmax=minmax,
    )


def test_table_and_files_name_same_functions():
    table = table_functions()
    assert len(table) > 15
    assert table == declared_functions()


def test_no_function_calls_slow_builtin_in_loop_or_block():
    for path in sorted(PRELUDE.glob("*.agc")):
        assert slow_calls(path.read_text(encoding="utf-8")) == [], path.name


def test_check_finds_slow_calls():
    text = """\
def f(list: List[Int]) -> Int
  for x in list
    list = list.drop(1)
  end
  return 0
end
"""
    assert slow_calls(text) == ["3: list = list.drop(1)"]
    block = """\
def f(m: Map[Int, Int]) -> Void
  keys = m.keys
  m.each do |k| k.take(1) end
end
"""
    assert slow_calls(block) == ["3: m.each do |k| k.take(1) end"]


def test_methods_agree_with_python_peer_on_random_lists(tmp_path):
    random.seed(2518)
    alphabet = ["a", "b", "ab", "\u00e9", "z", "\u65e5\u672c", "A", "\U0001f600", "", "aa"]
    for case in range(8):
        numbers = [random.randint(-6, 12) for _ in range(random.choice([0, 1, 2, 7, 11]))]
        words = [random.choice(alphabet[:6]) for _ in range(random.choice([0, 3, 9]))]
        floats = [random.choice([0.5, 1.5, -2.0, 2.0, float("nan")]) for _ in range(random.choice([0, 1, 4, 6]))]
        names = [random.choice(alphabet) for _ in range(random.choice([0, 1, 5, 8]))]
        path = tmp_path / ("case%d.agc" % case)
        text = peer_program(numbers, words, floats, names)
        path.write_text(text, encoding="utf-8")
        result = run(cli() + [str(path)])
        assert result.code == 0, result.stderr + text
        assert result.stdout.splitlines() == peer_lines(numbers, words, floats, names), text


def slices(items, n):
    """Python peer of Lazy.each_slice: groups of n items, the last one shorter."""
    group = []
    for item in items:
        group.append(item)
        if len(group) == n:
            yield group
            group = []
    if group:
        yield group


def windows(items, n):
    """Python peer of Lazy.each_cons: every run of n neighbours."""
    window = []
    for item in items:
        window = (window + [item])[-n:]
        if len(window) == n:
            yield list(window)


def lazy_peer_lines(numbers, size, count):
    """Compute the output of lazy_peer_program() with Python generators, one item at a time like the VM."""
    def naturals():
        n = 1
        while True:
            yield n
            n += 1

    def chunks(items):
        group = []
        for item in items:
            if group and item != group[-1] + 1:
                yield group
                group = []
            group.append(item)
        if group:
            yield group

    doubled = [n * 2 for n in numbers]
    kept = [n for n in numbers if n % 3 != 0]
    lines = [
        show(("ok", doubled)),
        show(("ok", list(itertools.islice((n for n in naturals() if n % 7 == 3), count)))),
        show(("ok", list(slices(iter(numbers), size)))),
        show(("ok", list(windows(iter(numbers), size)))),
        show(("ok", list(chunks(iter(numbers))))),
        show(("ok", [n * i for i, n in enumerate(kept)])),
        show(("ok", list(itertools.islice((x for n in numbers for x in (n, -n)), count)))),
        show(("ok", list(itertools.dropwhile(lambda n: n < 5, numbers[count:])))),
        show(("ok", list(itertools.takewhile(lambda n: n < 5, numbers)))),
        show(("ok", sum(numbers))),
    ]
    found = next((n for n in numbers if n > 9), None)
    lines.append(show(("ok", found) if found is not None else ("error", "not found")))
    return lines


def lazy_peer_program(numbers, size, count):
    """Build one Agentica program of Lazy pipelines whose output is checked against lazy_peer_lines()."""
    return """\
def main() -> Void
  numbers: List[Int] = [{numbers}]
  puts(numbers.lazy.map do |n| n * 2 end.to_a.to_s)
  puts(Lazy.produce(1) do |n| n + 1 end.filter do |n| n % 7 == 3 end.first({count}).to_s)
  puts(numbers.lazy.each_slice({size}).to_a.to_s)
  puts(numbers.lazy.each_cons({size}).to_a.to_s)
  puts(numbers.lazy.chunk_while do |a, b| b == a + 1 end.to_a.to_s)
  puts(numbers.lazy.filter do |n| n % 3 != 0 end.with_index do |n, i| n * i end.to_a.to_s)
  puts(numbers.lazy.flat_map do |n| [n, -n] end.take({count}).to_a.to_s)
  puts(numbers.lazy.drop({count}).drop_while do |n| n < 5 end.to_a.to_s)
  puts(numbers.lazy.take_while do |n| n < 5 end.to_a.to_s)
  puts(numbers.lazy.reduce(0) do |total, n| total + n end.to_s)
  puts(numbers.lazy.find do |n| n > 9 end.to_s)
end
""".format(numbers=", ".join(map(literal, numbers)), size=size, count=count)


def test_lazy_agrees_with_python_generators_on_random_lists(tmp_path):
    random.seed(1727)
    for case in range(6):
        numbers = [random.randint(-6, 12) for _ in range(random.choice([0, 1, 2, 7, 11]))]
        size = random.choice([1, 2, 3, 5])
        count = random.choice([0, 1, 3, 8])
        path = tmp_path / ("lazy%d.agc" % case)
        text = lazy_peer_program(numbers, size, count)
        path.write_text(text, encoding="utf-8")
        result = run(cli() + [str(path)])
        assert result.code == 0, result.stderr + text
        assert result.stdout.splitlines() == lazy_peer_lines(numbers, size, count), text


def composed_peer_lines(numbers, size, count):
    """Expected output of composed_peer_program(): two or three steps in a row, as Python generators."""
    def chunks(items):
        group = []
        for item in items:
            if group and item < group[-1]:
                yield group
                group = []
            group.append(item)
        if group:
            yield group

    take = itertools.islice
    return [
        show(("ok", list(slices(itertools.takewhile(lambda n: n < 9, numbers), size)))),
        show(("ok", list(take(slices(iter(numbers), size), count)))),
        show(("ok", list(windows((x for n in numbers for x in (n, n + 1)), size)))),
        show(("ok", list(chunks(take(numbers, count))))),
        show(("ok", list(take(windows(slices(iter(numbers), 2), 2), count)))),
    ]


def composed_peer_program(numbers, size, count):
    """Build one Agentica program of composed Lazy steps, checked against composed_peer_lines()."""
    return """\
def main() -> Void
  numbers: List[Int] = [{numbers}]
  puts(numbers.lazy.take_while do |n| n < 9 end.each_slice({size}).to_a.to_s)
  puts(numbers.lazy.each_slice({size}).take({count}).to_a.to_s)
  puts(numbers.lazy.flat_map do |n| [n, n + 1] end.each_cons({size}).to_a.to_s)
  puts(numbers.lazy.take({count}).chunk_while do |a, b| b >= a end.to_a.to_s)
  puts(numbers.lazy.each_slice(2).each_cons(2).first({count}).to_s)
end
""".format(numbers=", ".join(map(literal, numbers)), size=size, count=count)


def test_composed_lazy_steps_agree_with_python_generators(tmp_path):
    random.seed(4121)
    for case in range(6):
        numbers = [random.randint(-6, 12) for _ in range(random.choice([0, 1, 2, 7, 11]))]
        size = random.choice([1, 2, 3])
        count = random.choice([0, 1, 3, 8])
        path = tmp_path / ("composed%d.agc" % case)
        text = composed_peer_program(numbers, size, count)
        path.write_text(text, encoding="utf-8")
        result = run(cli() + [str(path)])
        assert result.code == 0, result.stderr + text
        assert result.stdout.splitlines() == composed_peer_lines(numbers, size, count), text


def test_compare_agrees_with_python_code_point_order(tmp_path):
    random.seed(77)
    alphabet = ["a", "b", "A", "\u00e9", "z", "\u65e5", "\U0001f600", "\u00ff", "\uffff"]
    pairs = [("", ""), ("a", ""), ("ab", "abc"), ("abc", "abc"), ("\u00e9", "z"), ("\U0001f600", "\uffff")]
    for _ in range(60):
        left = "".join(random.choices(alphabet, k=random.randint(0, 3)))
        right = "".join(random.choices(alphabet, k=random.randint(0, 3)))
        pairs.append((left, right))
    comparisons = "\n".join(
        '  puts(String.compare("%s", "%s").to_s)' % pair for pair in pairs
    )
    left, right = pairs[4]
    program = """\
def main() -> Void
{comparisons}
  puts("{left}".compare("{right}").to_s)
end
""".format(comparisons=comparisons, left=left, right=right)
    path = tmp_path / "compare.agc"
    path.write_text(program, encoding="utf-8")
    result = run(cli() + [str(path)])
    assert result.code == 0, result.stderr
    order = [str((a > b) - (a < b)) for a, b in pairs]
    assert result.stdout.splitlines() == order + [order[4]]


def test_typo_of_prelude_only_builtin_has_no_hint(tmp_path):
    cases = (
        ('__fail_ar("RUNTIME-INVALID-COUNT", 1, "no")', "CHECK-UNKNOWN-NAME"),
        ('fail_arg("RUNTIME-INVALID-COUNT", 1, "no")', "CHECK-UNKNOWN-NAME"),
        ('[1]._fail_arg("RUNTIME-INVALID-COUNT", 1, "no")', "CHECK-UNKNOWN-METHOD"),
    )
    for body, code in cases:
        path = tmp_path / "typo.agc"
        program = f"""\
def main() -> Void
  {body}
end
"""
        path.write_text(program, encoding="utf-8")
        result = run(cli() + ["--json", "check", str(path)])
        assert result.code == 1, body
        found = json.loads(result.stderr)
        assert found["code"] == code, body
        assert "fail_arg" not in found.get("help", ""), body
