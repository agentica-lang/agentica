---
title: Regex (std)
weight: 13
description: The std/regex module, which searches, extracts, replaces and splits text with regular expressions in linear time.
---

`std/regex` is written in Agentica: `import Regex from "std/regex"`. It takes the syntax of RE2 and Go, gives the leftmost-first match, and counts positions in characters, as `index_of` and `slice` do. Its matcher has no backtracking, so a search takes time in proportion to the length of the text times the size of the pattern, whatever the input. Nothing in it halts: a bad pattern or template is an error.

```ruby
Regex.compile(pattern: String) -> Result[Regex.Regex]
Regex.match?(text: String, re: Regex.Regex) -> Bool
Regex.match(text: String, re: Regex.Regex) -> Result[Regex.Match]
Regex.find_all(text: String, re: Regex.Regex) -> List[Regex.Match]
Regex.replace(text: String, re: Regex.Regex, template: String) -> Result[String]
Regex.split(text: String, re: Regex.Regex) -> List[String]
Regex.escape(text: String) -> String
Regex.named(m: Regex.Match, name: String) -> Result[Regex.Group]
```

The text comes first, so a pipe reads like the call: `text |> Regex.split(re)`. A fixed pattern is written as a regex literal, `/pattern/flags`; `Regex.compile` is for a pattern built at run time.

```agentica
import Regex from "std/regex"

def read_year(text: String) -> Result[String]
  found = try Regex.match(text, /(?P<year>\d{4})-\d{2}-\d{2}/)
  year = try Regex.named(found, "year")
  return ok(year.text)
end

def main() -> Void
  puts(read_year("released on 2026-11-01"))
  puts(Regex.replace("Ada Lovelace", /(\w+) (\w+)/, "$2, $1"))
  puts("a, b;c" |> Regex.split(/[,;]\s*/))
  puts(Regex.find_all("7 apples, 12 pears", /\d+/).map do |m| m.text end)
  puts(Regex.match?("No Digits", /digits/i))
  fruit = Regex.compile("\\b" + Regex.escape("pears") + "\\b").unwrap!
  puts(Regex.match?("7 pears", fruit))
  puts(Regex.compile("(ab"))
end
```

```output
ok("2026")
ok("Lovelace, Ada")
["a", "b", "c"]
["7", "12"]
true
true
error("character 4: missing ')' for the group at character 1")
```

`Regex.escape(text)` gives a pattern that matches `text` literally. A pattern given to `Regex.compile` is a `String`, so each backslash of the pattern is written twice: `"\\d+"` is the pattern `\d+`.

## Regex literals

A regex literal is `Regex.compile` of its body, checked when the program is compiled. The body is the pattern as written, with no string escapes: `/\d+\.\d+/` is the pattern `\d+\.\d+`, and `\/` is a slash. The file must import `std/regex`, in any form; without one the literal is `CHECK-REGEX-IMPORT`. A pattern that `compile` refuses is `CHECK-INVALID-REGEX`, at the character the error names, so a literal never fails at run time and needs no `unwrap!`. A literal in a function is built once, before `main`, even inside a loop.

- Flags follow the closing slash: `i` ignores case and is `(?i)`; `m` lets `.` match a newline and is `(?s)`. `/a.b/im` is the pattern `(?is)a.b`, which is also its `source`. Another letter, or a flag written twice, is `LEX-REGEX-FLAG`.
- `#{` cannot appear in the body (`LEX-REGEX-INTERPOLATION`); `\#{` matches the text `#{`. Build a pattern from values with `Regex.compile`.
- The body ends at the line end: a missing closing slash is `LEX-UNTERMINATED-REGEX`.
- After a value, `/` is division: `a / b / c` divides, and `x /= 2` is the compound operator. After an operator, a comma, an opening bracket or a keyword it starts a literal: `[/a/, /b/]`, `return /a/`. A call needs its parentheses: `puts(/x/)`; `puts /x/` is a division and an error. A line that starts with `/ 2` is a literal that does not end; put the `/` at the end of the line before.
- A literal is not a `case` pattern: test it in an `if` with `Regex.match?`.

Watch out, coming from Ruby: `^` and `$` are text anchors, so `/^ERROR/` matches only at the start of the text; write `/(?m)^ERROR/` for line starts. The `m` flag means "dot matches newline", as in Ruby, while `(?m)` inside the pattern means line anchors. There is no `=~` and no `$1`: use `Regex.match` and the groups of the match.

## Matches

```ruby
struct Regex.Match
  text: String               # the whole match, the same as groups[0].text
  start: Int                 # character index of its first character
  stop: Int                  # character index after its last character
  groups: List[Regex.Group]  # groups[0] is the whole match
  names: Map[String, Int]    # group name to its index in groups
end

struct Regex.Group
  text: String               # "" when the group did not take part
  start: Int                 # -1 when the group did not take part
  stop: Int                  # -1 when the group did not take part
  matched: Bool
end
```

Groups are numbered from 1 by their opening parenthesis. `Regex.named(m, name)` reads a named group, and an unknown name is an error. A `Regex.Regex` holds the pattern as `source`; only `compile` and a regex literal make one. Printing a `Regex.Regex` shows `source` first, then its compiled program.

- `match?` says whether the pattern matches anywhere. It keeps no groups, so it is the cheapest search.
- `match` gives the leftmost-first match, or `error("no match")`. Among alternatives the first that matches wins: `a|ab` on `ab` gives `a`.
- `find_all` gives every match from left to right, without overlaps. After an empty match the search moves one character on, and an empty match right where the previous match ended is dropped, as in Go: replacing `x*` with `-` in `abxd` gives `-a-b-d-` (Python gives `-a-b--d-`).
- `replace` replaces every match that `find_all` finds.
- `split` cuts the text at each match that takes at least one character and keeps the empty parts: `,a,,b,` split at `,` is `["", "a", "", "b", ""]`. An empty match separates nothing; to get the characters use `s.split("")`.

## Templates

In the template of `replace`, `$0` is the whole match, `$1` to `$N` a group, `${name}` a named group, `${N}` a group by number, and `$$` a dollar sign. `$N` takes every digit that follows, so `$10` is group 10; write `${1}0` for group 1 and a `0`. A group that did not take part gives `""`. The template is checked before any text is replaced: another `$` form or a group the pattern does not have is an error, such as `no group 10`.

Watch the two forms that look alike: in an Agentica string `"#{name}"` puts the value of the variable `name` into the string, while `"${name}"` is template text that `replace` reads as the group called `name`. Write `"#{...}"` only to build the template from your own values.

## Syntax

- Literals: any character except `\ . + * ? ( ) | [ ] { } ^ $`. A backslash before a punctuation character makes it literal. Escapes: `\n \r \t \f \v`, `\x7F` and `\x{10FFFF}`.
- `.` matches any character except a newline; with `(?s)` it matches a newline too.
- Classes: `[abc]`, ranges `[a-z]`, negation `[^a-z]`, escapes and the classes below inside. A `]` first in a class and a `-` first or last are literal.
- `\d` `[0-9]`, `\w` `[0-9A-Za-z_]`, `\s` `[\t\n\f\r ]`, and their negations `\D \W \S`. They are ASCII only.
- Anchors: `^` and `$` are the start and the end of the text, or of a line with `(?m)`; `\A` and `\z` are always the start and the end of the text; `\b` and `\B` are an ASCII word boundary and its negation.
- Groups: `(...)` captures, `(?:...)` does not, `(?P<name>...)` and `(?<name>...)` capture with a name.
- Alternation `|`, leftmost-first.
- Repetition: `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}`, each lazy with a `?` after it (`*?`). A `{` that starts no repetition is literal: `a{,3}` matches the text `a{,3}`.
- Flags: `(?i)` ignores case (ASCII letters only), `(?m)` makes `^` and `$` work on lines, `(?s)` lets `.` match a newline. `(?i-s)` turns flags on and off, and `(?i:...)` sets them for a group. A flag set in the middle of a group lasts to the end of that group.

Not supported, each an error from `compile`: backreferences (`\1`), lookahead and lookbehind, atomic groups, possessive repetitions, `\Q...\E`, Unicode classes such as `\pL`, POSIX classes such as `[[:alpha:]]`, the escapes `\a` and `\0`, octal escapes, and `\b` inside a class.

Where it differs from Ruby: `^` and `$` are text anchors, not line anchors (write `(?m)^` for a line start), and `(?m)` means lines, not "dot matches newline" (`(?s)` here). Where it differs from Python's `re`: `$` does not match before a final newline, `\d \w \s \b` are ASCII as with `re.ASCII`, `\B` matches in the empty text, as in Go, and the empty-match rule of `find_all` and `split` follows Go.

## Errors and limits

A compile error starts with the character where it is, counted from 1: `character 4: missing ')' for the group at character 1`. A pattern has at most 4096 characters, a repetition count at most 1000, at most 10000 instructions after its repetitions are expanded (`(?:a{1000}){11}` is too large), groups nested at most 256 deep and at most 256 groups.

## Cost

Every loop of the matcher charges steps, so a long search shares the machine with other tasks and `--max-steps` stops it with `RUNTIME-STEP-LIMIT`. A search on a text of n characters with a pattern of m instructions and g groups costs O(n·m·g) steps, and `match?` O(n·m). `find_all`, `replace` and `split` run one search per match. `(a+)+$`, which takes exponential time in a backtracking matcher, takes linear time here. To stop a search after some time, run it in a task and await it with a timeout (`Task.await(task, timeout_ms)`).

`find_all` returns every match at once, so a pattern that matches every character makes one `Match` per character. Compile a run-time pattern once, outside the loop that uses it; a literal is built once already.
