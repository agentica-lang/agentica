"""The compiler prelude: the methods written in Agentica in stdlib/prelude/ (docs/future/25-ruby-typed-idioms.md 25.6).

Three kinds of check:

- the table of compiler/prelude_data.agc and the files of stdlib/prelude/ name the same functions, and no function
  calls an O(n) builtin inside a loop or a callback (no binary needed);
- a Python peer, written apart from the Agentica bodies, computes the results of the methods on random lists, with the
  tie, NaN and String-order rules of 25.6, and the output of one program must equal it;
- `String.compare` agrees with the code point order of Python on random strings.
"""
import json
import math
import random
import re

from tests.agentica_test import ROOT, TestCase, cli, run

PRELUDE = ROOT / "stdlib" / "prelude"
TABLE = (ROOT / "compiler" / "prelude_data.agc").read_text(encoding="utf-8")

# Calls that cost O(n) in the length of a list or a map: in a loop, a block or a callback they make a quadratic run
# whose steps still look linear.
SLOW_IN_A_LOOP = re.compile(r"\.(concat|take|drop|reverse|sort|sort_by|keys|values|delete)\b")
LOOP_START = re.compile(r"^(\s*)(for|while)\b")


def table_functions() -> dict[str, str]:
    """Return function names and file stems from compiler/prelude_data.agc rows."""
    found = {}
    row = re.compile(
        r'Model\.PreludeRow\((?:(?!Model\.PreludeRow\().)*?'
        r'module: "([a-z]+)".*?bodies: (\{[^}]*\})',
        flags=re.DOTALL,
    )
    for module, bodies in row.findall(TABLE):
        for name in re.findall(r': "([a-z_]+)"', bodies):
            found[name] = module
    return found


def declared_functions():
    """{function name: file stem} from the `def` lines of the files of stdlib/prelude/."""
    found = {}
    for path in sorted(PRELUDE.glob("*.agc")):
        for name in re.findall(r"^def ([a-z_]+)\(", path.read_text(encoding="utf-8"), flags=re.MULTILINE):
            found[name] = path.stem
    return found


class PreludeFiles(TestCase):
    def test_the_table_and_the_files_name_the_same_functions(self):
        table = table_functions()
        self.assertGreater(len(table), 15)
        self.assertEqual(table, declared_functions())

    def test_no_function_calls_an_o_n_builtin_inside_a_loop_or_a_block(self):
        for path in sorted(PRELUDE.glob("*.agc")):
            self.assertEqual(slow_calls(path.read_text(encoding="utf-8")), [], path.name)

    def test_the_check_finds_such_a_call(self):
        text = "def f(list: List[Int]) -> Int\n  for x in list\n    list = list.drop(1)\n  end\n  return 0\nend\n"
        self.assertEqual(slow_calls(text), ["3: list = list.drop(1)"])
        block = "def f(m: Map[Int, Int]) -> Void\n  keys = m.keys\n  m.each do |k| k.take(1) end\nend\n"
        self.assertEqual(slow_calls(block), ["3: m.each do |k| k.take(1) end"])


def slow_calls(text):
    """The lines of a prelude source that call an O(n) builtin inside a loop (the lines indented under its header) or
    in a block, as "number: line"."""
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
    """The text `to_s` gives an Agentica value, for the lists, maps, Floats and Results of these tests."""
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
    """min_by or max_by over the indexes of keys: the first index whose key beats every earlier one; a NaN key never
    wins unless every key is NaN."""
    if not keys:
        return ("error", "the list is empty")
    best = 0
    for index in range(1, len(keys)):
        key = keys[index]
        if key == key and (keys[best] != keys[best] or wins(key, keys[best])):
            best = index
    return ("ok", best)


def peer_lines(numbers, words, floats, names):
    """What the program of PreludePeer.program() prints, computed with plain Python."""
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
    for n in numbers:
        # Agentica's % truncates toward zero, as in C, so -5 % 3 is -2; Python's % would give 1.
        groups.setdefault(int(math.fmod(n, 3)), []).append(n)
    lines.append(show(groups))
    counts = {}
    for word in words:
        counts[word] = counts.get(word, 0) + 1
    lines.append(show(counts))
    lines.append(show(list(dict.fromkeys(words))))
    lines.append(show(sum(numbers)))
    total = 0.0
    for x in floats:
        total += x
    lines.append(show(total))
    # Python compares str by code point, the order String.compare and sort give.
    for keys in (numbers, floats, names):
        lines.append(show(pick(keys, lambda a, b: a < b)))
        lines.append(show(pick(keys, lambda a, b: a > b)))
    return lines


class PreludePeer(TestCase):
    def program(self, numbers, words, floats, names):
        """One `puts` for each line of peer_lines(). min_by and max_by pick an index, so ties show which one won."""
        lines = [
            "def main() -> Void",
            "  nan = Float.from_bits(9221120237041090560)",
            "  numbers: List[Int] = [%s]" % ", ".join(map(literal, numbers)),
            "  words: List[String] = [%s]" % ", ".join(map(literal, words)),
            "  floats: List[Float] = [%s]" % ", ".join(map(literal, floats)),
            "  names: List[String] = [%s]" % ", ".join(map(literal, names)),
            "  puts(numbers.find do |n| n % 5 == 0 end.to_s)",
            "  puts(numbers.flat_map do |n| [n, -n] end.to_s)",
            "  puts(numbers.partition do |n| n % 2 == 0 end.to_s)",
            "  puts(numbers.take_while do |n| n < 5 end.to_s)",
            "  puts(numbers.drop_while do |n| n < 5 end.to_s)",
            "  puts(numbers.each_slice(1).to_s)",
            "  puts(numbers.each_slice(3).to_s)",
            "  puts(numbers.group_by do |n| n % 3 end.to_s)",
            "  puts(words.tally.to_s)",
            "  puts(words.uniq.to_s)",
            "  puts(numbers.sum.to_s)",
            "  puts(floats.sum.to_s)",
        ]
        for name in ("numbers", "floats", "names"):
            for method in ("min_by", "max_by"):
                lines.append("  puts((0...%s.size).to_a.%s do |i| %s[i] end.to_s)" % (name, method, name))
        return "\n".join(lines + ["end", ""])

    def test_the_methods_agree_with_a_python_peer_on_random_lists(self):
        random.seed(2518)
        alphabet = ["a", "b", "ab", "\u00e9", "z", "\u65e5\u672c", "A", "\U0001f600", "", "aa"]
        work = self.make_temp_dir()
        for case in range(8):
            numbers = [random.randint(-6, 12) for _ in range(random.choice([0, 1, 2, 7, 11]))]
            words = [random.choice(alphabet[:6]) for _ in range(random.choice([0, 3, 9]))]
            floats = [random.choice([0.5, 1.5, -2.0, 2.0, float("nan")]) for _ in range(random.choice([0, 1, 4, 6]))]
            names = [random.choice(alphabet) for _ in range(random.choice([0, 1, 5, 8]))]
            path = work / ("case%d.agc" % case)
            text = self.program(numbers, words, floats, names)
            path.write_text(text, encoding="utf-8")
            result = run(cli() + [str(path)])
            self.assertEqual(result.code, 0, result.stderr + text)
            self.assertEqual(result.stdout.splitlines(), peer_lines(numbers, words, floats, names), text)

    def test_compare_agrees_with_the_code_point_order_of_python(self):
        random.seed(77)
        alphabet = ["a", "b", "A", "\u00e9", "z", "\u65e5", "\U0001f600", "\u00ff", "\uffff"]
        pairs = [("", ""), ("a", ""), ("ab", "abc"), ("abc", "abc"), ("\u00e9", "z"), ("\U0001f600", "\uffff")]
        for _ in range(60):
            pairs.append(("".join(random.choices(alphabet, k=random.randint(0, 3))),
                          "".join(random.choices(alphabet, k=random.randint(0, 3)))))
        lines = ["def main() -> Void"]
        lines += ['  puts(String.compare("%s", "%s").to_s)' % pair for pair in pairs]
        lines += ['  puts("%s".compare("%s").to_s)' % pairs[4], "end", ""]
        path = self.make_temp_dir() / "compare.agc"
        path.write_text("\n".join(lines), encoding="utf-8")
        result = run(cli() + [str(path)])
        self.assertEqual(result.code, 0, result.stderr)
        order = [str((a > b) - (a < b)) for a, b in pairs]
        expected = order + [order[4]]
        self.assertEqual(result.stdout.splitlines(), expected)


class PreludeOnlyName(TestCase):
    def test_a_typo_of_the_prelude_only_builtin_gets_no_hint_that_names_it(self):
        work = self.make_temp_dir()
        for body, code in (('__fail_ar("RUNTIME-INVALID-COUNT", 1, "no")', "CHECK-UNKNOWN-NAME"),
                           ('fail_arg("RUNTIME-INVALID-COUNT", 1, "no")', "CHECK-UNKNOWN-NAME"),
                           ('[1]._fail_arg("RUNTIME-INVALID-COUNT", 1, "no")', "CHECK-UNKNOWN-METHOD")):
            path = work / "typo.agc"
            path.write_text("def main() -> Void\n  %s\nend\n" % body, encoding="utf-8")
            result = run(cli() + ["--json", "check", str(path)])
            self.assertEqual(result.code, 1, body)
            found = json.loads(result.stderr)
            self.assertEqual(found["code"], code, body)
            self.assertNotIn("fail_arg", found.get("help", ""), body)
