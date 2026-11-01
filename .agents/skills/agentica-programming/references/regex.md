# Regex (`std/regex`)

`import Regex from "std/regex"`. Regular expressions with the RE2 and Go
syntax, leftmost-first, in linear time (no backtracking). Written in Agentica;
nothing halts. Positions count characters.

```text
Regex.compile(pattern: String) -> Result[Regex.Regex]
Regex.match?(text: String, re: Regex.Regex) -> Bool
Regex.match(text: String, re: Regex.Regex) -> Result[Regex.Match]   # error("no match")
Regex.find_all(text: String, re: Regex.Regex) -> List[Regex.Match]
Regex.replace(text: String, re: Regex.Regex, template: String) -> Result[String]
Regex.split(text: String, re: Regex.Regex) -> List[String]
Regex.escape(text: String) -> String
Regex.named(m: Regex.Match, name: String) -> Result[Regex.Group]

struct Regex.Match  # text, start, stop, groups: List[Regex.Group] (groups[0] is
                    # the whole match), names: Map[String, Int]
struct Regex.Group  # text, start, stop, matched; "" and -1 when not matched
```

- The pattern is a `String`: double each backslash (`"\\d+"`). Compile once,
  outside loops. Text first: `text |> Regex.split(re)`.
- Syntax: `. [a-z] [^a] \d \w \s \D \W \S` (ASCII), `^ $ \A \z \b \B`,
  `(...)`, `(?:...)`, `(?P<n>...)` or `(?<n>...)`, `|`, `* + ? {n} {n,}
  {n,m}` and lazy `*?`, flags `(?i)` (ASCII), `(?m)`, `(?s)`, `(?i:...)`. A
  `{` that starts no repetition is literal. No backreferences, lookaround,
  `\pL`: `compile` errors.
- `^ $` are text anchors (not Ruby's line anchors): use `(?m)^` for lines.
  `.` skips `\n` unless `(?s)`. `$` never matches before a final newline.
- `find_all`, `replace`: after an empty match move one character; drop an
  empty match where the last match ended (Go: `x*` → `-` in `abxd` is
  `-a-b-d-`). `split` cuts only at matches of 1+ characters, keeps empty parts.
- Template: `$0`, `$1`, `${1}`, `${name}`, `$$`; a missing group or another
  `$` form is an error. `"#{x}"` interpolates a variable; `"${x}"` is a group.
- Compile errors start with `character N: ` (from 1). Limits: 4096
  characters, counts up to 1000, 10000 instructions, 256 groups and depth.
- A search costs O(length · pattern size) steps; `--max-steps` stops it. For a
  time limit run it in a task and `Task.await(task, timeout_ms)`.
