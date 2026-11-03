## 48. Regular expressions

**Status:** built: 48a, 48b and 48c (`stdlib/regex.agc`, the literal in
`docs/grammar/04-lexical.md`, `vm/regex.c`); 48d (Unicode classes) is planned.
Decided by the owner on 2026-10-15: a linear-time matcher with no backtracking
(48.2), std first (48.3), after the bootstrap (§18), and a Ruby-style literal
`/pattern/flags` (48.6); roadmap row 7.10. The contract is the grammar (the
literal, its lexer rule and diagnostics), the
[site page](../../site/content/library/text-and-data/regex.md) (syntax, API,
errors, limits) and the programming skill; this section keeps the decisions and
their reasons.

### 48.1 Background

Strings have no raw form (`"\d"` is `LEX-INVALID-ESCAPE`), positions count
characters, not bytes, and a builtin runs to its end once started, so a C
matcher without a stepper could hold the scheduler for a whole scan
(`docs/vm/10-io-scheduler.md`, "Builtins").
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

- No backreferences and no lookaround ("backreferences are not supported").
- `{n,m}` expands the program, so `a{1000}` is about 1000 instructions.
- `find_all`, `replace` and `split` run one search per match, so the worst case
  is O(matches·n·m·g): `a+x|a` on n letters `a` reads to the end on each search
  (RE2 has the same cost; reasoned, not measured).
- Each `Save` copies a thread's immutable capture list, O(g); `match?` keeps no
  captures and costs O(n·m). The persistent vector of row 8 (8d) would make a
  copy O(log g) if a benchmark asks for it.

### 48.3 Implementation path (std first)

The pattern is parsed into a tree (each error carries the character position),
compiled to instructions (`Char`, `Class`, `Any`, `Split` in priority order,
`Jump`, `Save`, `Assert` for `^`, `$` and `\b`, and `Match`), and run by the
Pike VM over the code points: one thread list per step in priority order, each
program counter at most once, and a thread that reaches `Match` cuts the
lower-priority threads.

**Where:** `stdlib/regex.agc`, embedded as `std/regex` and imported as `import
Regex from "std/regex"`, as `std/toml` is. It is pure computation over existing
types, so the std-first rule applies: no builtin, no VM change, no front-end
change. It is fair without C: each loop iteration charges steps, a turn ends
after 2000 steps (`AGC_TURN_STEPS`), and a cancel takes effect at the next turn
(`docs/vm/14-core-invariants.md`, §14.3). `String.at` is O(1) only for ASCII
text (`docs/vm/05-values-execution-builtins.md` §1), so the matcher reads the
input once with `text.split("")` (one-character ASCII strings are shared) and
`String.code`.

**C only if measured (48c).** A benchmark pair in `benchmarks/` (the Agentica
program and a Python twin with `re.ASCII`) covers a literal, a class with `+`,
an alternation of ten words, a 1 MB log scan and the ReDoS pattern of 48.8. The
threshold for moving to C is set from those numbers (for example a simple
pattern more than 30 times slower than Python `re`); the owner confirms it.

The C matcher (`vm/regex.c`, entry `RegexEngine.search`, in a std-only builtin
module as `HttpWire` is, never under the `Regex` alias):

- The API, results and error texts do not change; only step counts do.
- It is a stepper, the protocol of `File.each_line`
  (`docs/vm/03-ir-and-bytecode.md` §4.3): each resume advances a bounded number
  of characters, charges one STEP and a turn cost per character. The turn cost
  never touches `--max-steps` (`docs/vm/10-io-scheduler.md`), so the STEP is
  what the budget sees and the ReDoS test still holds.
- Its thread lists live in a GC object that bytecode cannot reach, and its
  program has its own layout (exception 4 of the std-first rule).
### 48.4 Syntax supported

The RE2 and Go subset with Go's meaning, listed on the site page; each
unsupported form (backreferences, lookaround, atomic and possessive forms,
`\Q...\E`, `(?U)`) is a compile error, and Unicode classes (`\pL`, `\p{Greek}`)
come in 48d. `\d \w \s` and `\b` are ASCII only.

Where Python's `re` differs (checked on Python 3.13), which the peer must
handle:

- `\d`, `\w`, `\s` and `\b` are Unicode in a `str` pattern (the peer uses
  `re.ASCII`); `$` matches before a final newline (here only at the end, unless
  `(?m)`); `a{,3}` is a quantifier (here literal text, as in RE2).
- `\z`, `(?<name>...)`, a mid-pattern flag such as `a(?-i)b` and `\x{22}` are
  errors in Python, which has `\Z` and `(?P<name>...)`.
- Python keeps an empty last iteration: `(a*)*` on `aa` gives group 1 at (2, 2),
  so the peer compares group spans only outside repetitions (48.8).
- Leftmost-first is the same (`a|ab` on `ab` gives `a`); POSIX gives `ab`.
### 48.5 API decisions

The module is `std/regex`, with no new syntax. Each function returns a `Result`
for bad input and never halts, as `std/toml` does. The text comes first, as in
`String.split(s, sep)`, so `text |> Regex.split(re)` reads like the call. The
signatures and error messages are on the site page.

- `find_all` returns matches left to right without overlaps. After a
  zero-length match the search moves one character on, and a zero-length match
  where the previous match ended is dropped: Go's rule (its documentation, not
  run here). Python 3.7+ keeps it: `re.sub("x*", "-", "abxd")` is `-a-b--d-`
  there and `-a-b-d-` here.
- `replace` has the same zero-length rule, and the template (`$0`, `$N` with the
  longest digit run, `${N}`, `${name}`, `$$`) is checked against the groups
  before any text is replaced. In an Agentica string `"$2, $1"` needs no
  backslash; the site page warns that `"#{name}"` interpolates a variable while
  `"${name}"` is template text.
- `split` splits only at matches that consume at least one character, and keeps
  empty parts: a deliberate third rule. Python's `re.split(r"x*", "axbc")` gives
  `['', 'a', '', 'b', 'c', '']` (checked on 3.13) and Go's `Split` splits at
  zero-length matches too (not run here). Here a pattern that matches nothing
  separates nothing, so every piece is one the pattern describes; characters are
  `String.split(s, "")`.
- `escape` gives a pattern that matches its input literally.
- `Match` and `Group` are plain structs (`text`, `start`, `stop` in characters;
  `groups[0]` is the whole match; `names` maps a group name to its index; a
  group that did not take part has `""`, -1, -1 and `matched: false`).
  `Regex.Regex` holds the source and a compiled program of a private type
  `Program`: an importer cannot name or build it
  (`docs/grammar/05b-modules.md`), so no program can make a bad `Regex`. That
  relies on an exported struct having a private field type, which 48a checks.
- Limits are compile errors, never halts: pattern over 4096 characters,
  repetition count over 1000, over 10000 instructions after expansion, nesting
  over 256 levels, over 256 groups (proposals, tuned in 48a).
- An invalid regex literal is `CHECK-INVALID-REGEX` at its span (48.6); a
  string passed to `Regex.compile`, even a literal, is a run-time value and
  stays a `Result`.

### 48.6 The regex literal (decided 2026-10-15)

The owner decided that the backslash problem is solved by a Ruby-style literal,
`/pattern/flags`, new syntax built as 48b. `Regex.compile(String)` stays for
patterns built at run time. Options weighed: (a) `"\\d+"`, which doubles every
backslash; (b) a raw string `r"..."`, a general text form that cannot hold `"`,
not planned; (c) `/.../flags`, decided; (d) a heredoc, which needs two or more
lines and keeps the escapes, so it does not help a one-line pattern. The lexical
rules (the body, the flags `i` and `m`, when a `/` starts a literal, the
diagnostics) are in `docs/grammar/04-lexical.md`. Decisions behind them:

- **Flags.** Only `i` and `m`, each at most once. `m` means dot-all (`(?s)`), as
  in Ruby; RE2's `(?m)` line-anchor flag stays in the body. `x` is left out,
  since a literal is one line.
- **No interpolation.** `#{` in the body is `LEX-REGEX-INTERPOLATION`: without
  the rule `/#{name}/` would silently match the text `#{name}`.
- **Type and import.** The value has the type `Regex.Regex` of `std/regex`. The
  checker finds the module by its path, not its alias, and without an import the
  error is `CHECK-REGEX-IMPORT`. `Regex` is not reserved, as `HTTP` is not.
- **Checked, and built before `main`.** The checker runs the 48a parser on the
  body and flags, so an invalid literal cannot fail at run time. A literal is a
  call of std/regex's `compile` that the checker has proved succeeds: in a
  function body it becomes a constant, built once before `main` and only if a
  reachable function reads it; in a constant initializer it is built with that
  constant. Emitting the compiled program as data was weighed and left out: it
  would freeze the private `Program` layout into the front end. Building a
  literal charges steps, which count toward `--max-steps` before `main`.
- **No method form.** `/x/.match?(text)` is invalid (structs have no methods);
  write `Regex.match?(text, /x/)`. In a `case` pattern or an `import` path a
  literal is `PARSE-UNEXPECTED-TOKEN`.
- **Ruby differences** (stated next to the literal on the site page and in the
  skill): `^` and `$` are text anchors here, so `/^ERROR/` matches only at the
  start of the text and `/(?m)^ERROR/` gives line anchors; there is no `=~` and
  no `$1`.

### 48.7 Limits and cost

A search costs O(n·m·g) steps, charged by the loops (O(n·m) for `match?`);
`find_all`, `replace` and `split` cost O(matches·n·m·g) in the worst case. A
thread holds O(g) captures, and `find_all` returns every match, so a pattern
that matches each character makes one `Match` per character (the out-of-memory
exit 70 applies; a streaming form, as `File.each_line` is (§27.4), can come
later). Timeouts are not an argument: a caller runs the match in a task and
awaits it with a timeout; a cancel is seen at the next turn (§14.3), and the C
matcher checks the same flag between resumes.

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

- **48a: `std/regex` in Agentica** (built): parser, compiler, Pike VM, the
  functions, limits, goldens, peer, ReDoS test and benchmark.
- **48b: the regex literal (48.6)** (built), `compiler/` only: the lexer rule,
  the scanners, the node, `CHECK-INVALID-REGEX`, `CHECK-REGEX-IMPORT` and the
  lowering. A test checks that a literal equals `Regex.compile` of its body and
  mapped flags.
- **48c: C matcher** (built): a stepper with the same API (48.3).
- **48d: Unicode classes and case folding** (planned): `\p{L}`, `\pN`, scripts,
  and `(?i)` with simple Unicode folding. The tables are generated, like
  `vm/unicode_data.c` was, from the pinned UCD files by an Agentica program (see
  the header of `vm/unicode_data.c`).

Not planned: raw string literals.

### 48.10 Decisions and open questions

**Decided by the owner on 2026-10-15:**

1. The engine: a Pike VM, linear time, no backtracking, leftmost-first (48.2).
   Not PCRE2 or Oniguruma (backtracking, a new submodule) or libc `regcomp`.
2. Std first: `std/regex` in Agentica, C only if measured (48.3). `Regex` is a
   std module, not a builtin; the type is `Regex.Regex` (48.5, 48.6).
3. After the bootstrap: phase 29 and row 7.10.
4. The literal `/pattern/flags` (48.6). Raw strings are not planned.
5. Offsets are characters, as `index_of` and `slice` count. Case folding is
   ASCII in 48a and simple Unicode in 48d, with no locale rules.
6. Templates use `$` (`$N`, `${name}`, `$$`), not `\1`.

**Answered with the recommendations (A):**

1. **Match representation:** plain structs `Match` and `Group` (48.5); not an
   opaque `Match` with accessors or a builtin record. Plain data is what std
   first prefers, and the C matcher returns spans that std wraps.
2. **Method form:** module functions only (`Regex.find_all(text, re)`); a method
   on String (`text.scan(re)`) needs the compiler prelude (row 8.2), since a std
   module cannot add methods to a builtin type, and comes with row 8.2.
3. **Import for the literal:** the file imports `std/regex` in any form or gets
   `CHECK-REGEX-IMPORT`. Not an implicit load (a new rule: type names would
   depend on a module the file does not import); it can become implicit later
   without breaking a program.
4. **Ruby's anchors and `m`:** text anchors and dot-all `m`, with the warning in
   the site page and the skill. Not line anchors in the literal only (one syntax
   with two meanings), and not a literal without `m`.

### 48.11 Implementation (row 7.10)

One PR per item of 48.9, each with its own tests and docs. Done when: a program
searches, extracts, replaces and splits text with a pattern, literal or string;
no pattern stalls the VM past its step budget; the tests of §48.6 and §48.8
pass.
