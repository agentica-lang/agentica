## 48. Regular expressions

**Status:** Design, not scheduled. Deferred until after the bootstrap of §35
(step 8), as roadmap row 7.10 and phase 29
([`docs/roadmap/29-regex.md`](../roadmap/29-regex.md)) record. Nothing is
implemented. The owner decided on 2026-10-15 that the backslash problem is
solved by a Ruby-style regex literal, `/pattern/flags` (48.6). Its details are
proposals. The other open questions (48.10) need the owner's decision before
phase 29 starts.

The Ruby-style `Regex` was a "later utility" in [pending
roadmap](../roadmap/pending-general-programming-and-mcp.md). This section gives
it a design. The facts in 48.1 were checked against `origin/master` at 4baf84ec.

### 48.1 Today

- There is no regex. `=~` and `matches?` are listed as forms that do not exist
  (`.agents/skills/agentica-programming/SKILL.md`).
- The String builtins (`src/builtins.rkt`, the `String.` rows) are all literal
  text: `length`, `upcase`, `downcase`, `trim`, `split`, `join`, `contains?`,
  `starts_with?`, `ends_with?`, `replace`, `slice`, `index_of`, `at`, `reverse`,
  `code`, `from_code`, `from_int`, `from_float`, `from_bytes`, `to_int`,
  `to_float`, `to_int!` and `to_float!`.
- `String.replace` replaces every non-overlapping occurrence of a literal text.
  An empty `from` inserts at every position. `String.split` keeps empty parts
  (`docs/vm/02-reference-behavior.md` §2.3).
- Positions count characters (code points), not bytes: `length`, `at`, `slice`
  and `index_of` (`docs/grammar/06b-builtins.md`).
- A string literal has the escapes `\"`, `\\`, `\#`, `\n`, `\r` and `\t` and no
  others (`docs/grammar/04-lexical.md`, `ESCAPE`). So `"\d"` is
  `LEX-INVALID-ESCAPE`. There are no raw strings, and a literal stays on one
  line. Heredocs are planned (§25.10) and keep the escapes.
- A builtin runs to its end once it starts. A builtin whose work grows with its
  input charges a turn cost, but it cannot be switched out halfway
  (`docs/vm/10-io-scheduler.md`, "Builtins"). A regex matcher in C with no
  stepper could hold the scheduler for a whole scan.
- For "maybe", the language uses `Result[T]`: `String.index_of` and `Map.get`
  (two arguments) return `error(...)` when a value is absent. There is no
  builtin `Option`. `Option[T]` in the docs is a user enum.

### 48.2 Engine choice

**Proposal:** a linear-time engine, a Pike VM (an NFA simulation with thread
priorities, the approach of RE2 and Go's `regexp`). It has no backtracking, so a
search takes O(n·m) steps, where n is the number of characters and m is the
program size. No input makes it blow up. The matcher is ordinary Agentica code
(48.3), so each loop charges steps and `--max-steps` stops a runaway pattern
with `RUNTIME-STEP-LIMIT`, as for any loop.

| Engine | Kind | Backrefs and lookaround | Worst case | Dependency | Notes |
|---|---|---|---|---|---|
| Pike VM (proposal) | NFA, leftmost-first | no | O(n·m) per search | none | Same results as RE2 and Go on the subset |
| PCRE2 | backtracking, optional JIT | yes | exponential (ReDoS) | new `vm/third_party` submodule | Perl syntax, large C code |
| Oniguruma | backtracking | yes | exponential | new submodule | Ruby's engine, many syntaxes |
| POSIX `regcomp` (libc) | leftmost-longest | no (ERE) | depends on libc | libc, no submodule | Byte-based; classes and results vary by libc and locale |

Each new submodule needs the owner's approval (AGENTS.md). RE2 is C++, so it is
the reference design and not an option for the C core.

What linear time costs:

- No backreferences (`\1`) and no lookahead or lookbehind (`(?=`, `(?!`, `(?<=`,
  `(?<!`). The error says so: "backreferences are not supported".
- `{n,m}` expands the program, so `a{1000}` is about 1000 instructions. The
  limits of 48.7 bound it.
- Repeated searches cost more than one search. `find_all`, `replace` and `split`
  run a search for each match, so the worst case is O(matches·n·m). Take `a+x|a`
  on n letters `a`: each search reads to the end of the text, looking for an `x`
  that never comes. RE2 has the same cost (reasoned from its design, not
  measured here). The step budget bounds it (48.7).

Rough sizes (estimates, not measured here):

- `std/regex` in Agentica: a parser of about 600 lines, a compiler of about 300,
  a Pike VM of about 250 and the API of about 300, so about 1,500 lines.
- A C matcher, if 48c is needed: about 800 to 1,000 lines of C.
- PCRE2 and Oniguruma: each tens of thousands of lines of C, with their Unicode
  tables.

### 48.3 Implementation path (std first)

The pipeline:

1. Parse the pattern into a tree: characters and escapes, classes, groups,
   alternation and repetition. Each error carries the character position.
2. Compile the tree to a program of instructions: `Char`, `Class`, `Any`,
   `Split` (in priority order), `Jump`, `Save` (a capture), `Assert` (`^`, `$`,
   `\b`) and `Match`.
3. Run the Pike VM over the code points of the text. Each step keeps one thread
   list in priority order, with each program counter at most once. When a thread
   reaches `Match`, the threads of lower priority are cut.

**Where:** `stdlib/regex.agc`, embedded as `std/regex` and imported as
`import Regex from "std/regex"`, as `std/toml` is (§45.4). It is pure
computation over types that exist, so the roadmap's "std first" rule applies:
no builtin, no VM change, no front-end change.

**Why std needs no C to be fair:** each loop iteration charges steps, and a turn
ends after 2000 steps (`AGC_TURN_STEPS`, `docs/vm/10-io-scheduler.md`). A long
search is switched out by the scheduler, and a cancel takes effect at the next
turn (`docs/vm/14-core-invariants.md`, §14.3).

**Input access:** `String.at` is O(1) only for ASCII text, where `chars` equals
`bytes` (`docs/vm/05-values-execution-builtins.md` §1). So the matcher reads the
input once with `text.split("")` (the one-character ASCII strings are shared,
`docs/vm/17-lists.md`) and `String.code` for each character. The memory of that
list is measured in 48a.

**Measure first (48a):** a benchmark pair in `benchmarks/`, an Agentica program
and a Python twin that uses `re.ASCII`. It covers a literal, a class with `+`,
an alternation of ten words, a 1 MB log scan and the ReDoS pattern of 48.8.

**Move to C only if the numbers ask for it (48c).** Proposal: the threshold is
set from the 48a numbers, for example when the simple patterns run more than 30
times slower than Python `re` on the same machine. The owner confirms the
threshold in the 48a PR.

The C step, when it comes:

- The API and its results do not change, including the error texts. Only step
  counts change, as the std-first rule says.
- It runs as a stepper, the protocol of `File.each_line`
  (`docs/vm/03-ir-and-bytecode.md` §4.3). Each resume advances a bounded number
  of characters and charges a turn cost per character. Its thread lists live in
  a GC object that bytecode cannot reach. No C code runs for longer than one
  slice.
- Its compiled program needs its own memory layout in the runtime. The std-first
  rule allows that as exception 4.
- Its public entry point goes under a builtin module whose first parameter fits,
  such as `String`. It never goes under `Regex`, the std import alias.

### 48.4 Syntax supported

The RE2 and Go subset (proposal), with Go's meaning for each form:

- Literals: any character except `\ . + * ? ( ) | [ ] { } ^ $`. Escapes: a
  backslash before punctuation, `\n \r \t \f \v`, `\x7F` and `\x{10FFFF}`.
- `.` matches any character except a newline. `(?s)` lets it match a newline.
- Classes `[...]`: ranges such as `a-z`, negation `[^...]`, escapes inside, and
  the classes below.
- `\d \w \s`, and `\D \W \S` for their negations. They are ASCII only: `[0-9]`,
  `[0-9A-Za-z_]` and `[\t\n\f\r ]`.
- Anchors: `^` and `$` (the ends of the text, or of the lines with `(?m)`),
  `\A`, `\z`, and `\b` and `\B` (ASCII word boundaries).
- Groups: `(...)` captures, `(?:...)` does not, and named groups `(?P<name>...)`
  or `(?<name>...)`. Groups are numbered from 1 in the order of their opening
  parentheses.
- Alternation `|`, leftmost-first (48.5).
- Quantifiers `*`, `+`, `?`, `{n}`, `{n,}` and `{n,m}`, and their lazy forms
  with a `?` after them. A `{` that does not start a valid repetition is literal
  text, as in RE2.
- Flags `(?i)`, `(?m)` and `(?s)`, with `(?-i)` to turn one off, and the scoped
  form `(?i:...)`.

Not in the subset: backreferences, lookaround, atomic and possessive forms,
`\Q...\E` and `(?U)`. Each is a compile error. Unicode classes (`\pL`,
`\p{Greek}`) come in 48d, so `\p` is an error until then.

Where Python's `re` differs. These were checked on Python 3.13 unless marked:

- In a `str` pattern, `\d`, `\w`, `\s` and `\b` are Unicode:
  `re.fullmatch(r"\d", "٣")` matches, and with `re.ASCII` it does not. The peer
  uses `re.ASCII`.
- `$` matches before a final newline in Python: `re.search(r"a$", "a\n")`
  matches. Here `$` matches only at the end of the text, unless `(?m)`.
- In Python `a{,3}` is a quantifier, and it matches `aaa` in `aaaa`. Here `{,3}`
  is literal text, as in RE2 (not run here).
- Leftmost-first is the same: `re.search(r"a|ab", "ab").group()` is `a`, and
  that is what the subset gives. POSIX gives `ab`.

### 48.5 API proposal

The module is `std/regex`, with no new syntax. Each function returns a `Result`
when its input is bad, and never halts, as `std/toml` does.

```text
Regex.compile(pattern: String) -> Result[Regex.Regex]
Regex.match?(re, text) -> Bool
Regex.match(re, text) -> Result[Regex.Match]
Regex.find_all(re, text) -> List[Regex.Match]
Regex.replace(re, text, template: String) -> Result[String]
Regex.split(re, text) -> List[String]
Regex.escape(text: String) -> String
Regex.named(m: Regex.Match, name: String) -> Result[Regex.Group]
```

- `compile` parses and compiles. An error message starts with the place, as the
  TOML parser does: `character 9: missing ')' for the group at character 1`.
- `match?` stops at the first match and keeps no captures.
- `match` returns the leftmost-first match. With no match it returns
  `error("no match")`.
- `find_all` returns every match from left to right, with no overlaps. After a
  zero-length match the search moves one character on. A zero-length match that
  starts where the previous match ended is dropped. This is the rule of Go's
  `regexp` package (its documentation, not run here). Python 3.7 and later keep
  that match: `re.sub("x*", "-", "abxd")` is `-a-b--d-` in Python and `-a-b-d-`
  by the Go rule.
- `replace` replaces every match, as `String.replace` does, with the same rule
  for zero-length matches. The template is checked against the groups before the
  replacing starts (48.10 question 8).
- `split` splits at each match that is not zero-length, and keeps empty parts.
  Text without a match gives `[text]`.
- `escape` gives a pattern that matches the text literally. Round trip:
  `Regex.match(compile(escape(s)), s)` finds `s`.
- `named` looks up a group by name. An unknown name is `error(...)`.

The match values (proposal, 48.10 question 3):

```text
struct Match               # exported by std/regex
  text: String             # the whole match; the same as groups[0].text
  start: Int               # character index of its first character
  end: Int                 # character index after its last character
  groups: List[Group]      # groups[0] is the whole match
  names: Map[String, Int]  # group name to its index in groups
end

struct Group
  text: String             # "" when the group did not take part
  start: Int               # -1 when the group did not take part
  end: Int                 # -1 when the group did not take part
  matched: Bool
end
```

`Regex.Regex` holds the source and a compiled program of a private type. An
importer cannot name or build that type (`docs/grammar/05b-modules.md`), so a
program cannot make a `Regex` with a bad program. That relies on an exported
struct having a field of a private type. 48a checks it.

Four short examples, with the literal of 48.6. A pattern built at run time is
`Regex.compile(text)`, which returns a `Result`:

```agentica
import Regex from "std/regex"

def read_year(text: String) -> Result[String]
  found = try Regex.match(/(?P<year>\d{4})-\d{2}-\d{2}/, text)
  year = try Regex.named(found, "year")
  return ok(year.text)
end

def main() -> Void
  for line in ["ERROR 42 disk full", "info ok"]
    if Regex.match?(/ERROR (\d+)/, line)
      puts(line)
    end
  end
end

def swap_names(text: String) -> Result[String]
  return Regex.replace(/(\w+) (\w+)/, text, "$2, $1")
end

def split_tags(text: String) -> List[String]
  return Regex.split(/[,;]\s*/, text)
end
```

Errors. Compile errors are `error(message)`, with the place first. The kinds:

- Syntax: `missing ')'`, `unexpected ')'`, `missing ']'`, `invalid escape`,
  `invalid repetition` (such as `{3,2}`), `nested repetition` (such as `a**`),
  `unknown flag`.
- Unsupported: `backreferences are not supported`,
  `lookaround is not supported`, `\p is not supported yet` (until 48d).
- Limits: `pattern longer than 4096 characters`, `repetition count above 1000`,
  `program larger than 10000 instructions`, `nested deeper than 256 levels`,
  `more than 256 groups`.
- Templates: `no group 3` and `no group named "x"`.

Static check. A regex literal is checked at compile time (48.6), so an invalid
one is `CHECK-INVALID-REGEX` at its span. A string passed to `Regex.compile`,
even a string literal, is a run-time value and stays a `Result`.

### 48.6 The regex literal (decided 2026-10-15)

The owner decided that the backslash problem is solved by a Ruby-style regex
literal, `/pattern/flags`. It is new syntax, so it comes after the bootstrap, as
item 48b of phase 29, after the library of 48a. `Regex.compile(String)` stays
for patterns built at run time. A raw string literal is not planned.

The options that were weighed:

- (a) Live with `"\\d+"`. The mistake `"\d"` is `LEX-INVALID-ESCAPE`, so it is
  caught at once, but every pattern is doubled.
- (b) A raw string, `r"\d+"`. A general text form, not a regex one, and it
  cannot hold `"`. Not planned.
- (c) A regex literal, `/\d+/`, as in Ruby. Decided.
- (d) A heredoc. It needs two or more lines and keeps the escapes (§25.10), so
  it does not help a one-line pattern.

**Body.** The body is the pattern, with no string escapes: `\d` is `\d`. The
literal ends at the first `/` not preceded by a backslash, even inside `[...]`,
so a slash in a class is written `\/`. The regex parser reads `\/` as a literal
slash, so the lexer keeps the body as written. A line break before the closing
slash is `LEX-UNTERMINATED-REGEX`, at the opening slash. In the body `#` is
pattern text, never a comment.

**Flags (proposal).** After the closing slash come the letters `i` and `m`, each
at most once, in any order. `i` is case-insensitive (ASCII in 48a) and `m` lets
`.` match a newline. These are Ruby's meanings (from Ruby's documentation; Ruby
is not installed here), and they map to `(?i)` and `(?s)`. Ruby's `m` is not
RE2's `(?m)`, which stays available inside the body for line anchors. Any other
letter (`x`, `o`, `u`, `n`, `e`, `s`) is `LEX-REGEX-FLAG` at the letter. `x` is
left out on purpose: a literal is one line, so extended mode adds little.

**Interpolation (proposal): none.** `#{` in the body is
`LEX-REGEX-INTERPOLATION`, with a help line: a run-time pattern is
`Regex.compile(...)`, and `\#{` matches the text `#{`. The pattern must be known
to be checked, and without this rule `/#{name}/` would silently match the text
`#{name}`.

**Type and import (proposal, question 10).** The value has the type
`Regex.Regex` of `std/regex`. A file that uses a literal imports the module as
`Regex`, with `import Regex from "std/regex"`. Without that import the checker
reports `CHECK-REGEX-IMPORT`.

**Checked, and built once.** The checker runs the parser of 48a on the body and
the flags. An invalid literal is `CHECK-INVALID-REGEX` at the literal's span,
with the message of 48.5 as a help line, so a literal cannot fail at run time.
Lowering builds each literal once, as a constant, before `main` and only if a
reachable function uses it (`docs/grammar/06-semantics.md`). A literal in a loop
costs nothing per iteration.

**The lexer rule.** A `/` outside a string or a comment starts a literal when
the previous token cannot end an operand. Operand ends are: an integer or float
literal, a string literal, a lowercase name (including names ending in `?` or
`!`), a constant name such as `Int` or `Regex`, `true`, `false`, `nil`, `end`,
the closing `)`, `]` or `}`, and a regex literal. Every other token starts a
literal: `NL`, an operator, `(`, `[`, `{`, `,`, `=`, the start of the file, and
a keyword such as `return`, `if` or `do`. After an operand end, `/` is division.
This works because a call with arguments needs parentheses
(`docs/grammar/05b-modules.md`, `06b-builtins.md`), so a name followed by a
literal is never a call.

The ambiguous cases:

- `a / b / c` and `n /2`: a name before `/` is division.
- `a /b/` and `puts /x/`: the name makes the `/` a division, so these are parse
  errors, as `a / b /` is. Write `puts(/x/)`.
- `f(/x/)`, `[/x/, /y/]`, `x == /x/` and `return /x/`: literals.
- `(a)/2` and `size/2`: division, since `)` and a name end an operand.
- A line break: outside `(...)`, `[...]` and `{...}` the lexer emits `NL`
  (`docs/grammar/04-lexical.md`), so a line that starts with `/x/` is a literal.
  Inside those delimiters no `NL` is emitted, so `(a` and then `/ 2)` on the
  next line is division.
- `/x/.match?(text)`: not valid, since a struct has no methods. Write
  `Regex.match?(/x/, text)`.

**What the lexers need.** Neither lexer changes before the bootstrap. The freeze
of row 7.2.7 allows no new syntax in `src/`, so the Racket lexer
(`src/lexer.rkt`) does not get the literal. After the bootstrap the change is
only in `compiler/`. It needs: a state for the previous token, which is the last
token the lexer emitted; a body scanner that skips a backslash with the next
character and stops at `/`, at a line break or at `#{`; a flag scanner; a token
kind `regex` with its body, flags and span; an expression node for it in the
parser; the checker rule; and the constant lowering. The grammar changes go to
`docs/grammar/04-lexical.md` (the token), `06-semantics.md` (the value) and
`07-diagnostics.md` (the codes).

**Differences from Ruby.** `^` and `$` are text anchors unless the body has
`(?m)`, where Ruby's are always line anchors. `m` means the same as in Ruby.
There is no `=~` and no `$1` after a match: use `Regex.match`, `Regex.named` or
the groups of the result.

### 48.7 Limits and cost

- Limits are compile errors, never halts: a pattern of 4096 characters, a
  repetition count of 1000, a program of 10,000 instructions after expansion, a
  nesting depth of 256 (as `std/toml`) and 256 capture groups. The numbers are
  proposals, to be tuned in 48a with the benchmark.
- Input has no length limit. A search costs O(n·m) steps, charged by the loops.
  `find_all`, `replace` and `split` cost O(matches·n·m) in the worst case
  (48.2).
- Memory: a thread holds its captures, so a list holds O(m·groups) values.
  `find_all` returns every match. A pattern that matches each character creates
  one `Match` for each character, so O(matches·groups) memory. The VM's
  out-of-memory exit (70) applies. A streaming form, one block call per match as
  `File.each_line` does (§27.4), can come later.
- Timeouts: there is no timeout argument. A caller that needs one runs the match
  in a task and awaits it with a timeout (`Task.await`, phase 17c, §27.3). A
  cancel is seen at the next turn (§14.3). The C matcher of 48c checks the same
  flag between resumes.

### 48.8 Tests

- **Goldens** in `tests/fixtures/vm/regex-*.agc` (`make goldens`): the syntax of
  48.4, leftmost-first alternation, the zero-length rule, templates, `split`,
  the limits and the round trip of `escape`. Each new fixture gets hand-checked
  expected output (`docs/vm/README.md` §1).
- **Python peer** in `tests/test_regex.py` (unittest, standard library only). It
  runs the same patterns through `re.ASCII` and compares the matches and their
  spans. The differences of 48.4 are left out and listed in the test file: `$`
  before a final newline, `{,n}`, and zero-length splits.
- **Go rules.** No Go toolchain is in CI. Leftmost-first, the zero-length rule
  and the end-only `$` are pinned by hand-checked goldens. A Go peer needs the
  owner's approval to add the tool to CI.
- **ReDoS regression.** `(a+)+$` on `"a" * n + "!"` runs under a `--max-steps`
  budget that is a fixed multiple of n times the program size. Two sizes are
  enough. The test uses no clock. Python's `re` shows the risk: 0.08 s at 20
  characters, 0.34 s at 22, and about four times longer for each two more
  (measured on Python 3.13 here).
- **Slow tier.** A generated corpus of random patterns from the subset and
  random texts over a small alphabet, compared with Python's `re`. It is marked
  `@slow` and runs with `AGENTICA_TEST_SLOW=1`, which `make test-slow` sets.
- **Benchmark** (48a): the Agentica program and its Python twin in
  `benchmarks/`, run by `make bench`. The numbers go in the PR.

### 48.9 Phases

Each item has its own PR, with its own tests and docs, as phase 27 does.

- **48a: `std/regex` in Agentica.** The parser, compiler and Pike VM; `compile`,
  `match`, `match?`, `find_all`, `replace`, `split`, `escape` and `named`; the
  limits; the goldens, the peer, the ReDoS test and the benchmark. Docs: the
  site page `site/content/library/text-and-data/regex.md`, the programming skill
  (the "no regex" line in `SKILL.md`, a `references/regex.md` and its row in the
  table), and a `CHANGELOG.md` entry under `[Unreleased]`.
- **48b: the regex literal (48.6).** The lexer rule, the body and flag scanners,
  the expression node, `CHECK-INVALID-REGEX`, `CHECK-REGEX-IMPORT` and the
  constant lowering. `compiler/` only, after the bootstrap. Tests: lexer goldens
  for each ambiguous case of 48.6 (the token kinds), a golden for each new code
  with its span, and a check that a literal's value equals `Regex.compile` of
  the same body with its flags mapped. Docs: `docs/grammar/04-lexical.md`,
  `06-semantics.md`, `07-diagnostics.md`, and the programming skill, which then
  shows the literal as the normal form.
- **48c: C matcher, if measured.** A stepper with the same API (48.3). The PR
  records the numbers and the threshold.
- **48d: Unicode classes and case folding.** `\p{L}`, `\pN` and scripts, and
  `(?i)` with simple Unicode folding. The tables are generated like
  `vm/unicode_data.c` (from `vm/tools/gen-unicode.rkt`, which is Racket).
  Whether that generator stays after the bootstrap is open (§35).

Not planned: raw string literals (48.6).

### 48.10 Open questions

Each question has options and a recommendation. None is decided.

1. **The engine.** Options: (A) a Pike VM in Agentica, with C only if measured;
   (B) PCRE2; (C) Oniguruma; (D) libc `regcomp`. **Recommendation:** (A). It is
   linear, needs no new dependency, and follows the std-first rule. (B) and (C)
   bring backtracking and need the owner's approval for a submodule. (D) is
   byte-based and differs by libc.

2. **Match semantics.** Options: (A) leftmost-first, as Perl, Python, RE2 and
   Go; (B) leftmost-longest, as POSIX. **Recommendation:** (A). A Pike VM gets
   it from the thread order, and users expect it.

3. **The match representation.** Options: (A) plain structs `Match` and `Group`
   with `groups` and `names` (48.5); (B) an opaque `Match` with accessors only,
   so its shape can change; (C) a builtin record, like `HttpResponse`.
   **Recommendation:** (A). It is plain data, which the std-first rule prefers,
   and the C matcher returns spans that std wraps. (B) stays possible.

4. **Character or byte offsets.** Options: (A) characters, as `index_of` and
   `slice` count; (B) bytes; (C) both. **Recommendation:** (A). It is the unit
   of the rest of String. A byte form can be added later if a caller needs one.

5. **The literal syntax.** **Decided (2026-10-15):** option (C), a Ruby-style
   regex literal, `/pattern/flags` (48.6). The owner set raw strings aside. The
   flags, the interpolation rule and the lexer rule of 48.6 are proposals.

6. **Builtin or std.** Options: (A) a std module, `std/regex`, so the type is
   `Regex.Regex` through the alias; (B) a builtin type and module named `Regex`,
   like `Set`, with reserved name and builtin rows. **Recommendation:** (A). It
   is pure computation, so the std-first rule applies. (B) would need the
   owner's reason to differ from that rule.

7. **Case folding.** Options: (A) ASCII in 48a; (B) simple Unicode folding in
   48d; (C) full Unicode folding and locale rules. **Recommendation:** (A) now
   and (B) in 48d. (C) and locale rules are out of scope, since results must not
   depend on the locale.

8. **The replacement template.** Options: (A) `\1` and `\k<name>` (Ruby style,
   the first idea); (B) `$1`, `${name}` and `$$` (Go style). **Recommendation:**
   (B). A template then needs no backslash, which avoids the problem of 48.6,
   and `$` has no meaning in Agentica strings.

9. **The method form.** Options: (A) module functions only, so
   `Regex.find_all(re, text)`; (B) a method on String, `text.scan(re)`. A std
   module cannot add methods to a builtin type, so (B) needs the compiler
   prelude (§25.6, row 8.2). **Recommendation:** (A) in 48a and (B) with row
   8.2.

10. **The import for the literal.** Options: (A) a file that uses a literal
    imports `std/regex` as `Regex`, and `CHECK-REGEX-IMPORT` says so otherwise;
    (B) the compiler loads `std/regex` for any file with a literal, so no import
    is needed, as in Ruby. (B) makes a file's type names depend on a module it
    does not import, which is a new rule of the module system.
    **Recommendation:** (A). It is explicit, like every other std type, and it
    can become (B) later without breaking a program.
