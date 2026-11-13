# Regex (`std/regex`)

`import Regex from "std/regex"`. Regular expressions with the RE2 and Go
syntax, leftmost-first, in linear time (no backtracking). Nothing halts.
Positions count characters.

```text
Regex.compile(pattern: String) -> Result[Regex.Regex]
Regex.match?(text: String, regex: Regex.Regex) -> Bool
Regex.match(text: String, regex: Regex.Regex) -> Result[Regex.Match]   # error("no match")
Regex.find_all(text: String, regex: Regex.Regex) -> List[Regex.Match]
Regex.replace(text: String, regex: Regex.Regex, template: String) -> Result[String]
Regex.split(text: String, regex: Regex.Regex) -> List[String]
Regex.escape(text: String) -> String
Regex.named(match: Regex.Match, name: String) -> Result[Regex.Group]

struct Regex.Match  # text, start, stop, groups: List[Regex.Group] (groups[0] is
                    # the whole match), names: Map[String, Int]
struct Regex.Group  # text, start, stop, matched; "" and -1 when not matched
```

- Write a fixed pattern as a literal, `/\d+/`: the checker compiles it
  (`CHECK-INVALID-REGEX`), it is built once even in a loop, and it needs no
  `unwrap!`. The file must import `std/regex` (`CHECK-REGEX-IMPORT`). The body
  has no string escapes (`\/` is a slash) and no `#{}`. Flags: `i` is `(?i)`,
  `m` is `(?s)` (`.` matches `\n`, as Ruby's `m`); `/a/im` has the `source`
  `(?is)a`. After a value `/` is division: `puts(/x/)`, not `puts /x/`. A
  literal is not a `case` pattern.
  The `LEX-` errors of a literal are in `diagnostics.md`.
- `Regex.compile(text)` is for a pattern built at run time: a `String`, so
  double each backslash (`"\\d+"`), and compile it once, outside loops. Text
  first: `text |> Regex.split(re)`.
- Syntax: `. [a-z] [^a] \d \w \s \D \W \S` (ASCII), `^ $ \A \z \b \B`,
  `(...)`, `(?:...)`, `(?P<n>...)` or `(?<n>...)`, `|`, `* + ? {n} {n,}
  {n,m}` and lazy `*?`, flags `(?i)` (ASCII), `(?m)`, `(?s)`, `(?i:...)`. A
  `{` that starts no repetition is literal. No backreferences, lookaround,
  `\pL`, `[[:alpha:]]`, `\a`, `\0`: `compile` errors.
- `^ $` are text anchors (not Ruby's line anchors): use `(?m)^` for lines,
  `/(?m)^ERROR/`. `.` skips `\n` unless `(?s)` or the `m` flag. `$` never
  matches before a final newline. No `=~` and no `$1`: use `Regex.match` and
  its groups.
- `find_all`, `replace`: after an empty match move one character, as Go does.
  `split` cuts only at matches of 1+ characters, keeps empty parts.
- Template: `$0`, `$1`, `${1}`, `${name}`, `$$`; a missing group or another
  `$` form is an error. `"#{x}"` interpolates a variable; `"${x}"` is a group.
- Compile errors start with `character N: ` (from 1); a pattern is at most
  4096 characters.
- A search costs O(length · pattern size) steps; `--max-steps` stops it.
