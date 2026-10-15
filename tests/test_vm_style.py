"""Style rules of the C sources in vm/ (ported from vm-style-test.rkt): no type
definition after the first function, no prototype of a static function, and a
header comment of the right length in every file.

The scanner below finds the top-level declarations of a C file well enough for
these rules. It skips preprocessor lines (with continuations), comments and
string or character literals, so a brace inside any of them does not count.
"""
import re

from tests.agentica_test import ROOT, TestCase

VM_DIR = ROOT / "vm"

# Generated tables, not hand-written C.
SKIPPED = ("unicode_data.c",)


def _vm_files(root_pattern):
    found = [p.name for p in VM_DIR.iterdir() if re.search(root_pattern, p.name)]
    found += ["tests/" + p.name for p in (VM_DIR / "tests").iterdir() if p.name.endswith(".c")]
    return sorted(f for f in found if f not in SKIPPED)


def vm_files():
    return _vm_files(r"[.]c$")


def header_files():
    return _vm_files(r"[.][ch]$")


def header_problems(file, text):
    is_test = file.startswith("tests/")
    low, high = (1, 4) if is_test else (3, 8)

    def legal(comment):
        return re.match(r"[\s*]*(?i:copyright|spdx|licen[sc]e)", comment) is not None

    while True:
        m = re.match(r"\s*/\*(.*?)\*/(.*)\Z", text, re.DOTALL)
        if not m:
            return ["vm/%s: no header comment: the file must start with a /* */ comment of %d to %d lines"
                    % (file, low, high)]
        if legal(m.group(1)):
            text = m.group(2)
            continue
        body = [line for line in m.group(1).split("\n") if not re.match(r"[\s*]*\Z", line)]
        if low <= len(body) <= high:
            return []
        return ["vm/%s: header comment has %d line(s) of text, want %d to %d (references/vm-c.md)"
                % (file, len(body), low, high)]


def top_level_headers(text):
    """Return [(line, header)] for each top-level function, typedef, static declaration or data definition."""
    n = len(text)
    headers = []

    def at(i):
        return text[i] if i < n else "\0"

    i, line, depth, header, start, line_start = 0, 1, 0, "", None, True
    while i < n:
        c = at(i)
        if c == "\n":
            if depth == 0:
                header += " "
            i, line, start, line_start = i + 1, line + 1, start, True
            continue
        if line_start and c == "#":
            # A directive runs to the end of its line, over backslash continuations and comments.
            j = i
            while True:
                if j >= n:
                    break
                if at(j) == "\\" and at(j + 1) == "\n":
                    j += 2
                    line += 1
                elif at(j) == "/" and at(j + 1) == "*":
                    k = j + 2
                    while k < n and not (at(k) == "*" and at(k + 1) == "/"):
                        if at(k) == "\n":
                            line += 1
                        k += 1
                    j = k + 2 if k < n else k
                elif at(j) == "\n":
                    line += 1
                    j += 1
                    break
                else:
                    j += 1
            i, line_start = j, True
            continue
        line_start = False
        if c == "/" and at(i + 1) == "/":
            while i < n and at(i) != "\n":
                i += 1
        elif c == "/" and at(i + 1) == "*":
            i += 2
            while i < n and not (at(i) == "*" and at(i + 1) == "/"):
                if at(i) == "\n":
                    line += 1
                i += 1
            i += 2
        elif c in "\"'":
            j = i + 1
            while j < n and at(j) != c:
                j += 2 if at(j) == "\\" else 1
            if j < n and depth == 0:
                header += '""'
            i = j + 1
        elif c.isspace():
            if depth == 0:
                header += " "
            i += 1
            line_start = False
        elif depth == 0:
            if c == ";":
                if re.match(r"\s*(typedef\b|((_Noreturn|inline)\s+)*static\b)", header):
                    headers.append((start if start is not None else line, " ".join(header.split()) + ";"))
                header, start = "", None
            elif c == "{":
                headers.append((start if start is not None else line, " ".join(header.split())))
                depth, header, start = 1, "", None
            else:
                header += c
                start = start if start is not None else line
            i += 1
        elif c == "{":
            depth += 1
            i += 1
        elif c == "}":
            depth, header, start = depth - 1, "", None
            i += 1
        else:
            i += 1
    return headers


def header_kind(h):
    if re.search(r";$", h):
        if re.match(r"typedef\b", h):
            return "type"
        if re.search(r"=|^[^(]*\(\s*\*", h):
            return "data"
        return "prototype" if "(" in h else "data"
    if re.match(r"typedef\b", h):
        return "type"
    if "=" in h:
        return "data"
    if "(" in h:
        return "function"
    if re.match(r"((static|const|extern)\s+)*(struct|union|enum)\b", h):
        return "type"
    return "other"


def text_problems(file, text):
    headers = top_level_headers(text)
    first_function = next((line for line, h in headers if header_kind(h) == "function"), None)
    problems = []
    for line, h in headers:
        kind = header_kind(h)
        if kind == "prototype":
            problems.append("vm/%s:%d: prototype of a static function (define it before its first use): %s"
                            % (file, line, h))
        elif first_function is not None and line > first_function and kind == "type":
            problems.append("vm/%s:%d: type definition after the first function (line %d): %s"
                            % (file, line, first_function, h))
    return problems


class VmStyle(TestCase):
    def test_scanner_finds_functions_and_late_type_definitions(self):
        headers = top_level_headers(
            "#define M(x) /* {\n  } */ \\\n  { x }\n"
            "static int helper(int a);\n"
            "static void (*hook)(int);\n"
            "static int count, table[2];\n"
            "typedef struct { int a; } t;\n"
            "static const char *s = \"{\";\n"
            "struct p *f(struct p *q);\n"
            "static int g(void) {\n  struct p *x = 0;\n  return '}';\n}\n"
            "static const int k[] = {1};\n"
            "static struct p *h(void) { return 0; }\n"
            "struct late {\n  int b;\n};\n"
            "typedef struct late late_t;\n")
        self.assertEqual([line for line, _ in headers], [4, 5, 6, 7, 8, 10, 14, 15, 16, 19])
        self.assertEqual([header_kind(h) for _, h in headers],
                         ["prototype", "data", "data", "type", "data", "function", "data", "function",
                          "type", "type"])

    def test_late_types_and_static_prototypes_are_reported_with_their_lines(self):
        problems = text_problems(
            "x.c",
            "_Noreturn static void stop(void);\n"
            "int f(void) {\n  return 0;\n}\n"
            "struct x {\n  int a;\n};\n"
            "inline static int g(void);\n"
            "static int f2(void);\n")
        self.assertEqual([re.match(r"vm/x[.]c:(\d+):", p).group(1) for p in problems], ["1", "5", "8", "9"])

    def test_no_late_type_definition_or_static_prototype_in_vm_c_files(self):
        files = vm_files()
        self.assertIn("interp.c", files)
        problems = [p for f in files for p in text_problems(f, (VM_DIR / f).read_text(encoding="utf-8"))]
        self.assertEqual(problems, [], "\n".join(problems))

    def test_header_comment_bounds(self):
        def body(n):
            return "\n".join(" * line %d" % i for i in range(n))

        def source(n):
            return "/*\n" + body(n) + "\n */\nint x;\n"

        self.assertEqual(header_problems("a.c", source(3)), [])
        self.assertEqual(header_problems("a.c", source(8)), [])
        self.assertEqual(len(header_problems("a.c", source(2))), 1)
        self.assertEqual(len(header_problems("a.c", source(9))), 1)
        self.assertEqual(header_problems("tests/a_test.c", source(1)), [])
        self.assertEqual(header_problems("tests/a_test.c", source(4)), [])
        self.assertEqual(len(header_problems("tests/a_test.c", source(5))), 1)
        self.assertEqual(header_problems("a.c", "/* Copyright 2026 */\n" + source(3)), [])
        self.assertRegex(header_problems("a.c", "int x;\n/* late */\n")[0], r"\Avm/a[.]c: no header comment")
        self.assertRegex(header_problems("a.c", "// line\nint x;\n")[0], r"\Avm/a[.]c: no header")
        self.assertEqual(header_problems(
            "a.c", "/*\n * The license check of the TLS adapter.\n * Two.\n * Three.\n */\nint x;\n"), [])
        self.assertEqual(len(header_problems("a.c", "/* Copyright 2026 */\nint x;\n/* late */\n")), 1)
        self.assertEqual(len(header_problems("a.c", "/* Copyright 2026 */\n/* one line */\nint x;\n")), 1)
        self.assertEqual(header_problems("a.c", "/*\n * one\n *\n * two\n *\n * three\n */\nint x;\n"), [])
        self.assertEqual(len(header_problems("a.c", "/*\n * one\n *\n *\n * two\n */\nint x;\n")), 1)

    def test_every_vm_c_file_starts_with_a_header_comment_of_the_right_length(self):
        files = header_files()
        self.assertIn("interp.c", files)
        self.assertIn("port.h", files)
        self.assertIn("tests/map_test.c", files)
        problems = [p for f in files for p in header_problems(f, (VM_DIR / f).read_text(encoding="utf-8"))]
        self.assertEqual(problems, [], "\n".join(problems))
