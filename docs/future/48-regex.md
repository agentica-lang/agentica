## 48. Regular expressions

**Status:** Decided by the owner on 2026-10-15: a linear-time matcher with no
backtracking (48.2), std first (48.3), after the bootstrap (§18, done), and a
Ruby-style regex literal `/pattern/flags` (48.6). Roadmap row 7.10 records it.
Nothing is implemented. The decisions are in 48.10, with four open questions.

The Ruby-style `Regex` was a "later utility" in [pending
roadmap](../roadmap/pending-general-programming-and-mcp.md).

### 48.1 Today

- There is no regex: `=~` and `matches?` do not exist
  (`.agents/skills/agentica-programming/references/builtins.md`).
- The String builtins work on literal text (`agentica help String`). Positions
  count characters, not bytes (`docs/grammar/06b-builtins.md`).
- The string escapes are `\"`, `\\`, `\#`, `\n`, `\r` and `\t`
  (`docs/grammar/04-lexical.md`), so `"\d"` is `LEX-INVALID-ESCAPE`. There are
  no raw strings.
- "Maybe" is `Optional[T]`: `String.index_of` and `Map.get` (two arguments)
  return `none` when a value is absent.
- A builtin runs to its end once started, so a C matcher without a stepper could
  hold the scheduler for a whole scan (`docs/vm/10-io-scheduler.md`,
  "Builtins").

### 48.2 Engine choice

**Decided (2026-10-15):** a Pike VM, an NFA simulation with thread priorities,
as in RE2 and Go's `regexp`. It has no backtracking, so no input makes it blow
up. The matcher is ordinary Agentica code (48.3), so each loop charges steps and
`--max-steps` stops a runaway pattern with `RUNTIME-STEP-LIMIT`.

Not chosen:

- **PCRE2** (backtracking, optional JIT): Perl syntax, backreferences and
  lookaround, but exponential worst case (ReDoS), a new `vm/third_party`
  submodule and large C code.
- **Oniguruma** (Ruby's engine, backtracking): exponential worst case, a new
  submodule.
- **POSIX `regcomp`** (libc): leftmost-longest, no backreferences (ERE), but
  byte-based, and classes and results vary by libc and locale.

The Pike VM is an NFA, leftmost-first, with no backreferences or lookaround,
O(n·m·g) per search and no dependency; it gives the same results as RE2 and Go
on the subset. Each new submodule needs the owner's approval (AGENTS.md). RE2
is C++, so it is the reference design, not an option for the C core.

What linear time costs:

- No backreferences and no lookahead or lookbehind. The error says so:
  "backreferences are not supported".
- `{n,m}` expands the program, so `a{1000}` is about 1000 instructions (limits
  in 48.7).
- Repeated searches: `find_all`, `replace` and `split` run one search per match,
  so the worst case is O(matches·n·m·g), with g groups. Take `a+x|a` on n
  letters `a`: each search reads to the end, looking for an `x` that never
  comes. RE2 has the same cost (reasoned, not measured here).
- Captures: each `Save` copies a thread's immutable capture list, which costs
  O(g). One search costs O(n·m·g), and `match?`, which keeps no captures, costs
  O(n·m). 48a keeps the plain copy. The persistent vector of row 8 (8d) would
  make a copy O(log g), if a benchmark asks for it.

### 48.3 Implementation path (std first)

The pattern is parsed into a tree (each error carries the character position),
compiled to instructions (`Char`, `Class`, `Any`, `Split` in priority order,
`Jump`, `Save`, `Assert` for `^`, `$` and `\b`, and `Match`), and run by the
Pike VM over the code points. Each step keeps one thread list in priority
order, with each program counter at most once. A thread that reaches `Match`
cuts the lower-priority threads.

**Where:** `stdlib/regex.agc`, embedded as `std/regex` and imported as
`import Regex from "std/regex"`, as `std/toml` is. It is pure
computation over existing types, so the "std first" rule applies: no builtin, no
VM change, no front-end change.

**Fair without C:** each loop iteration charges steps, and a turn ends after
2000 steps (`AGC_TURN_STEPS`). A long search is switched out, and a cancel takes
effect at the next turn (`docs/vm/14-core-invariants.md`, §14.3).

**Input:** `String.at` is O(1) only for ASCII text
(`docs/vm/05-values-execution-builtins.md` §1). The matcher reads the input
once, with `text.split("")` (the one-character ASCII strings are shared,
`docs/vm/17-lists.md`) and `String.code`. The memory cost is measured in 48a.

**Measure (48a):** a benchmark pair in `benchmarks/`, an Agentica program and a
Python twin with `re.ASCII`, over a literal, a class with `+`, an alternation of
ten words, a 1 MB log scan and the ReDoS pattern of 48.8.

**Move to C (48c) only if the numbers ask for it.** The threshold is set from
the 48a numbers, for example a simple pattern more than 30 times slower than
Python `re` on the same machine. The owner confirms it in the 48a PR.

The C step, when it comes:

- The API and its results do not change, including the error texts. Only step
  counts change, as the std-first rule says.
- It is a stepper, the protocol of `File.each_line`
  (`docs/vm/03-ir-and-bytecode.md` §4.3). Each resume advances a bounded number
  of characters, charges one STEP (as `File.each_line` charges one per block
  call) and charges turn cost per character. The turn cost never touches
  `--max-steps` (`docs/vm/10-io-scheduler.md`), so the STEP is what the budget
  sees, and the ReDoS test of 48.8 still holds.
- Its thread lists live in a GC object that bytecode cannot reach. Its compiled
  program needs its own layout, which exception 4 of the std-first rule allows.
- Its entry point goes under a builtin module such as `String`, never under
  `Regex`, the std alias.

### 48.4 Syntax supported

The RE2 and Go subset (proposal), with Go's meaning:

- Literals: any character except `\ . + * ? ( ) | [ ] { } ^ $`. Escapes: a
  backslash before punctuation, `\n \r \t \f \v`, `\x7F` and `\x{10FFFF}`.
- `.` matches any character except a newline; `(?s)` lets it match one.
- Classes `[...]`: ranges, negation `[^...]`, escapes, and the classes below.
- `\d \w \s` and their negations `\D \W \S`, ASCII only: `[0-9]`,
  `[0-9A-Za-z_]`, `[\t\n\f\r ]`.
- Anchors `^` and `$` (the text ends, or the line ends with `(?m)`), `\A`, `\z`,
  and the ASCII word boundaries `\b` and `\B`.
- Groups `(...)` capture and `(?:...)` does not. Named groups are
  `(?P<name>...)` or `(?<name>...)`. Groups are numbered from 1 by their opening
  parenthesis.
- Alternation `|`, leftmost-first.
- Quantifiers `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}` and their lazy forms. A `{`
  that starts no valid repetition is literal text, as in RE2.
- Flags `(?i)`, `(?m)`, `(?s)`, `(?-i)` to turn one off, and the scoped
  `(?i:...)`.

Not in the subset: backreferences, lookaround, atomic and possessive forms,
`\Q...\E` and `(?U)`. Each is a compile error. Unicode classes (`\pL`,
`\p{Greek}`) come in 48d.

Where Python's `re` differs (checked on Python 3.13):

- In a `str` pattern, `\d`, `\w`, `\s` and `\b` are Unicode:
  `re.fullmatch(r"\d", "٣")` matches. With `re.ASCII` they are not. The peer
  uses `re.ASCII`.
- `$` matches before a final newline in Python (`re.search(r"a$", "a\n")`
  matches). Here it matches only at the end of the text, unless `(?m)`.
- `a{,3}` is a quantifier in Python. Here it is literal text, as in RE2 (not run
  here).
- `\z` and `(?<name>...)` are errors in Python, which has `\Z` and
  `(?P<name>...)`. A mid-pattern flag such as `a(?-i)b` is an error there too;
  `(?-i:...)` is valid in both. `\x{22}` is an error in Python.
- Python keeps an empty last iteration: `(a*)*` on `aa` gives group 1 at (2, 2).
  So the peer compares group spans only outside repetitions (48.8).
- Leftmost-first is the same: `re.search(r"a|ab", "ab").group()` is `a`. POSIX
  gives `ab`.

### 48.5 API proposal

The module is `std/regex`, with no new syntax. Each function returns a `Result`
for bad input and never halts, as `std/toml` does. The text comes first, as in
`String.split(s, sep)`, so `text |> Regex.split(re)` reads like the call.

```text
Regex.compile(pattern: String) -> Result[Regex.Regex]
Regex.match?(text, re) -> Bool
Regex.match(text, re) -> Result[Regex.Match]
Regex.find_all(text, re) -> List[Regex.Match]
Regex.replace(text, re, template: String) -> Result[String]
Regex.split(text, re) -> List[String]
Regex.escape(text: String) -> String
Regex.named(m: Regex.Match, name: String) -> Result[Regex.Group]
```

- `compile` parses and compiles. Its message starts with the place, as the TOML
  parser does: `character 9: missing ')' for the group at character 1`.
- `match?` stops at the first match and keeps no captures. `match` returns the
  leftmost-first match, or `error("no match")`.
- `find_all` returns every match from left to right, without overlaps. After a
  zero-length match the search moves one character on, and a zero-length match
  where the previous match ended is dropped. This is Go's rule (its
  documentation, not run here). Python 3.7 and later keep that match:
  `re.sub("x*", "-", "abxd")` is `-a-b--d-` there and `-a-b-d-` by Go's rule.
- `replace` replaces every match, as `String.replace` does, with the same
  zero-length rule. The template is checked against the groups before any text
  is replaced. `$0` is the whole match and `$N` is group N. `$N` takes the
  longest run of digits, so `$10` is group 10 and `$1x` is group 1 followed by
  `x`; `${1}x` ends the number early. `${name}` is a named group and `$$` is a
  dollar sign. Other `$` forms and missing groups (`no group 10`) are errors. In
  an Agentica string `"$2, $1"` needs no backslash. The site page warns that
  `"#{name}"` interpolates a variable, while `"${name}"` is template text.
- `split` splits at each match that consumes at least one character, and keeps
  empty parts. Skipping zero-length matches is a deliberate third rule. Python's
  `re.split` splits at them (`re.split(r"x*", "axbc")` gives
  `['', 'a', '', 'b', 'c', '']`, checked on 3.13), and Go's `Split` does too
  (not run here). Here a pattern that matches nothing separates nothing, so
  every piece is one the pattern describes. A caller who wants characters uses
  `String.split(s, "")`.
- `escape` gives a pattern that matches its input literally:
  `Regex.match(s, re)` finds `s` when `re` is compiled from `Regex.escape(s)`.
- `named` looks up a group by name. An unknown name is `error(...)`.

The match values (shape decided; question 1 open):

```text
struct Match               # exported by std/regex
  text: String             # the whole match; the same as groups[0].text
  start: Int               # character index of its first character
  stop: Int                # character index after its last character
  groups: List[Group]      # groups[0] is the whole match
  names: Map[String, Int]  # group name to its index in groups
end

struct Group
  text: String             # "" when the group did not take part
  start: Int               # -1 when the group did not take part
  stop: Int                # -1 when the group did not take part
  matched: Bool
end
```

`Regex.Regex` holds the source and a compiled program of a private type,
`Program`. An importer cannot name or build it (`docs/grammar/05b-modules.md`),
so no program can make a bad `Regex`. That relies on an exported struct having a
private field type; 48a checks it.

Examples, with the literal of 48.6. A run-time pattern is
`Regex.compile(text)`, which returns a `Result`:

```agentica
import Regex from "std/regex"

def read_year(text: String) -> Result[String]
  found = try Regex.match(text, /(?P<year>\d{4})-\d{2}-\d{2}/)
  year = try Regex.named(found, "year")
  return ok(year.text)
end

def swap_names(text: String) -> Result[String]
  return Regex.replace(text, /(\w+) (\w+)/, "$2, $1")
end

def split_tags(text: String) -> List[String]
  return text |> Regex.split(/[,;]\s*/)
end
```

Errors from `Regex.compile` are `error(message)`, with the place first:

- Syntax: `missing ')'`, `unexpected ')'`, `missing ']'`, `invalid escape`,
  `invalid repetition` (`{3,2}`), `nested repetition` (`a**`), `unknown flag`,
  `duplicate group name "a"`, and `\x{D800}` (not a scalar value).
- Unsupported: `backreferences are not supported`,
  `lookaround is not supported`, `\p is not supported yet` (until 48d).
- Limits: over 4096 characters, a repetition count over 1000, over 10000
  instructions after expansion, nesting over 256 levels, or over 256 groups.

Static check: an invalid regex literal is `CHECK-INVALID-REGEX` at its span
(48.6). A string passed to `Regex.compile`, even a string literal, is a run-time
value and stays a `Result`.

### 48.6 The regex literal (decided 2026-10-15)

The owner decided that the backslash problem is solved by a Ruby-style literal,
`/pattern/flags`. It is new syntax, so it comes as item 48b of phase 29, after
48a. `Regex.compile(String)` stays for patterns built at run time. A raw string
literal is not planned. The options weighed: (a) `"\\d+"`, which doubles every
backslash; (b) a raw string `r"..."`, a general text form that cannot hold `"`,
not planned; (c) `/.../flags`, decided; (d) a heredoc, which needs two or more
lines and keeps the escapes (heredocs, in the grammar), so it does not help a
one-line pattern.

**Body.** The body is the pattern, with no string escapes. The body scanner
reads a backslash together with the character after it, and stops at an
unescaped `/`, at a line break, or at `#{` (an error). So `/a\\/` is the pattern
`a\\`, a literal backslash. A slash in a class is written `\/`, which the regex
parser reads as a slash. A line break before the closing slash is
`LEX-UNTERMINATED-REGEX`. `#` is pattern text, never a comment.

**Flags (proposal, question 4).** After the closing slash come `i` and `m`, each
at most once, in any order. `i` is case-insensitive (ASCII in 48a). `m` lets `.`
match a newline, as in Ruby; here that is `(?s)`. RE2's `(?m)`, the line-anchor
flag, is not a literal flag and stays in the body. Any other letter (`x`, `o`,
`u`, `n`, `e`, `s`) is `LEX-REGEX-FLAG`. `x` is left out, since a literal is one
line.

**Interpolation (proposal): none.** `#{` in the body is
`LEX-REGEX-INTERPOLATION`, with the help: a run-time pattern is
`Regex.compile(...)`, and `\#{` matches the text `#{`. Without this rule
`/#{name}/` would silently match the text `#{name}`.

**Type and import (proposal, question 3).** The value has the type `Regex.Regex`
of `std/regex`. The checker finds the module by its path, not its alias, so
`import Regex from "std/regex"`, another alias, or
`import {compile} from "std/regex"` each satisfy the literal. Without one, the
error is `CHECK-REGEX-IMPORT`. `Regex` is not reserved, as `HTTP` is not
(`docs/grammar/04-lexical.md`); it is the usual alias.

**Checked, and built before `main`.** The checker runs the 48a parser on the
body and flags, so an invalid literal is `CHECK-INVALID-REGEX` at its span and
cannot fail at run time. Lowering emits the compiled program as data and builds
the private `Program` value from it. The program is not compiled inside the
constant, since a constant initializer cannot call a `def`
(`docs/grammar/06-semantics.md`). Each literal is a constant, built once, before
`main`, and only if a reachable function reads it. Building it charges steps,
which count toward `--max-steps` before `main`.

**The lexer rule.** A `/` outside a string or comment starts a literal when the
previous token cannot end an operand. Operand ends are: integer and float
literals, string literals, lowercase names (including names with a `?` or `!`
suffix), constant names such as `Int` or `Regex`, `true`, `false`, `nil`, `end`,
the closing `)`, `]` and `}`, and a regex literal. Every other token starts a
literal: `NL`, an operator, `(`, `[`, `{`, `,`, `=`, the start of the file, and
keywords such as `return`, `if` and `do`. After an operand end, `/` is division.
The regex check runs before the operator scanner's longest match, so `/=` is the
compound operator only after an operand end. A call with arguments needs
parentheses (`docs/grammar/05b-modules.md`, `06b-builtins.md`), so a name
followed by a literal is never a call.

The cases:

- `a / b / c`, `n /2`, `(a)/2` and `size/2` are division.
- `x /= 2` after a name is the operator; `f(/=x/)` is a literal with the body
  `=x`.
- `a /b/` and `puts /x/` are parse errors, as `a / b /` is. The help points to
  the call form, `puts(/x/)`.
- `f(/x/)`, `[/x/, /y/]`, `x == /x/` and `return /x/` are literals.
- Outside `(...)`, `[...]` and `{...}` a line break gives an `NL`
  (`docs/grammar/04-lexical.md`), so `/x/` at a line start is a literal. A line
  starting `/ 2` is `LEX-UNTERMINATED-REGEX`, with the help: put the operator at
  the end of the previous line, or wrap the expression in parentheses. Inside
  those delimiters no `NL` is emitted, so `(a` and then `/ 2)` is division.
- Inside `"#{...}"` the lexer is in code mode, so the body scanner runs there,
  and a `"` in the body does not end the string.
- In a `case` pattern or an `import` path a literal is `PARSE-UNEXPECTED-TOKEN`,
  with the help "a regex is not a pattern; compare with `Regex.match?`", as a
  constant is there.
- `/x/.match?(text)` is invalid, since structs have no methods. Write
  `Regex.match?(text, /x/)`.

**What the front end needs.** In `compiler/`: the previous token (the last one
emitted), a body scanner and a flag scanner (both in code mode), a token kind
`regex` with body, flags and span, a parser node, the checker rule and the
constant lowering. The grammar changes go to `docs/grammar/04-lexical.md`,
`06-semantics.md` and `07-diagnostics.md`. The diagnostic code names here and in
48.5 are proposals until 48b.

**Ruby differences (question 4).** `^` and `$` are text anchors here and line
anchors in Ruby, so `/^ERROR/` matches only at the start of the text.
`/(?m)^ERROR/` gives line anchors. `m` means dot-all here, as in Ruby. There is
no `=~` and no `$1`; use `Regex.match` and the groups. The site page and the
programming skill state these differences next to the literal.

### 48.7 Limits and cost

- Limits are compile errors, never halts: the numbers of 48.5. They are
  proposals, to be tuned in 48a.
- A search costs O(n·m·g) steps, charged by the loops (O(n·m) for `match?`).
  `find_all`, `replace` and `split` cost O(matches·n·m·g) in the worst case.
- Memory: a thread holds O(g) captures, and `find_all` returns every match, so a
  pattern that matches each character makes one `Match` per character. The VM's
  out-of-memory exit (70) applies. A streaming form, as `File.each_line` is
  (§27.4), can come later.
- Timeouts are not an argument. A caller runs the match in a task and awaits it
  with a timeout (`Task.await`, phase 17c). A cancel is seen at the next turn
  (§14.3), and the C matcher checks the same flag between resumes.

### 48.8 Tests

- **Goldens:** the syntax of 48.4, leftmost-first alternation, the zero-length
  rules, templates, `split`, the limits and the round trip of `escape`, with
  hand-checked expected output. No Go toolchain is in CI, so the Go rules
  (leftmost-first, zero-length, end-only `$`) are pinned by goldens.
- **Python peer** (standard library only): each pattern runs through `re` with
  `re.ASCII`, after two mechanical translations (`\z` to `\Z`, `(?<name>` to
  `(?P<name>`). Patterns Python still rejects are covered by goldens.
  Whole-match spans are always compared, group spans only outside repetitions
  (48.4).
- **Slow fuzzer** (`@slow`) over the compared subset only.
- **ReDoS.** `(a+)+$` on `"a" * n + "!"` runs under a `--max-steps` budget that
  is a fixed multiple of n times the program size, at two sizes, with no clock.
  The budget holds for the C matcher too (48.3).
- **Benchmark** (48a): the Agentica program and its Python twin, run by
  `make bench`.

### 48.9 Phases

- **48a: `std/regex` in Agentica.** The parser, compiler and Pike VM; `compile`,
  `match`, `match?`, `find_all`, `replace`, `split`, `escape` and `named`; the
  limits; goldens, peer, ReDoS test and benchmark. The site page carries the
  warning of 48.5 about `"#{name}"` and `"${name}"`.
- **48b: the regex literal (48.6).** The lexer rule, the scanners, the node,
  `CHECK-INVALID-REGEX`, `CHECK-REGEX-IMPORT` and the lowering. `compiler/`
  only, after 48a. A test checks that a literal equals `Regex.compile` of its
  body and mapped flags. The programming skill shows the literal as the normal
  form, with the Ruby differences.
- **48c: C matcher, if measured.** A stepper with the same API and one STEP per
  resume (48.3). The PR records the numbers and the threshold.
- **48d: Unicode classes and case folding.** `\p{L}`, `\pN`, scripts, and `(?i)`
  with simple Unicode folding. The tables are generated like `vm/unicode_data.c`
  was, from the pinned UCD files, by an Agentica program (the Racket generator
  is gone; see the header of `vm/unicode_data.c`).

Not planned: raw string literals.

### 48.10 Decisions and open questions

**Decided by the owner on 2026-10-15:**

1. The engine: a Pike VM, linear time, no backtracking, leftmost-first (48.2,
   48.5). Not chosen: PCRE2 and Oniguruma (backtracking, a new submodule), and
   libc `regcomp` (byte-based, varies by libc).
2. Std first: `std/regex` in Agentica, and C only if measured (48.3). `Regex` is
   a std module, not a builtin, and the type is `Regex.Regex` through the module
   (48.5, 48.6).
3. After the bootstrap: phase 29 and row 7.10.
4. The literal `/pattern/flags` (48.6). Raw strings are not planned.
5. Offsets are characters, as `index_of` and `slice` count (48.5). Case folding
   is ASCII in 48a and simple Unicode in 48d, with no locale rules.
6. Templates use `$` (`$N`, `${name}`, `$$`), not `\1` (48.5).

**Open questions:**

1. **The match representation.** Options: (A) plain structs `Match` and `Group`
   with `groups` and `names` (48.5); (B) an opaque `Match` with accessors only;
   (C) a builtin record, like `HttpResponse`. **Recommendation:** (A). It is
   plain data, which std first prefers, and the C matcher returns spans that std
   wraps.
2. **The method form.** Options: (A) module functions only,
   `Regex.find_all(text, re)` and `text |> Regex.split(re)`; (B) a method on
   String, `text.scan(re)`, which needs the compiler prelude (row 8.2),
   since a std module cannot add methods to a builtin type. **Recommendation:**
   (A) in 48a, and (B) with row 8.2.
3. **The import for the literal.** Options: (A) a file that uses a literal
   imports `std/regex` in any form, or gets `CHECK-REGEX-IMPORT`; (B) the
   compiler loads `std/regex` for any file with a literal, as Ruby does, so no
   import is needed. (B) makes type names depend on a module the file does not
   import, which is a new rule. **Recommendation:** (A). It is explicit, and it
   can become (B) later without breaking a program.
4. **Ruby's anchors and `m`.** Options: (A) text anchors and dot-all `m`, as
   proposed, with the warning in the site page and the programming skill; (B)
   line anchors for `^` and `$` in the literal only, which gives one syntax two
   meanings; (C) no `m` in the literal, so dot-all is `(?s)` in the body.
   **Recommendation:** (A), with the warning. The owner confirms it.

### 48.11 Implementation (row 7.10)

One PR per item of 48.9, each with its own tests and docs. 48b waits for 48a.

Done when: a program searches, extracts, replaces and splits text with a
pattern, literal or string; no pattern stalls the VM past its step budget; the
tests of §48.6 and §48.8 pass.
