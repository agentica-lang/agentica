# Performance

Measured facts for fast `.agc` code. Each number has a tag: `[PR #255]` is
the PR body (final head 6ac7a80, not merged yet), `[bench]` is the VM
benchmark notes, `[measured]` is one run on the release VM on 2026-10-15,
unless a run count is given. Times are milliseconds unless stated.

Time a piece of code inside the program:

```ruby
start = Time.monotonic_ns()
work()
ms = (Time.monotonic_ns() - start) / 1000000
```

## Lookup tables

Build a `Set` or `Map` once per call, then test with `include?` or `get`,
instead of a chain of comparisons. The lexer rewrite of PR #255 (tables and
a `while` loop) cut time by 13% to 32% against master: 1 MB of strings 1,241
to 910; 1 MB of identifiers 1,127 to 771; 1 MB of mixed source 1,918 to
1,664; gherkin (18.5 KB) 33.4 to 29.2. A `Set` test per character cost about
250 ns against about 680 ns for the old `name_char?` chain.

```ruby
def count_vowels(text: String) -> Int
  vowels: Set[String] = Set.new(["a", "e", "i", "o", "u"])
  total = 0
  for c in text.split("")
    if vowels.include?(c)
      total += 1
    end
  end
  return total
end
```

Character codes: for one pass over a text, `String.code(text.at(i))` is
enough. On 1M ASCII characters [measured, two runs]: building the codes once
with `text.split("").map do |c| String.code(c) end` took 129 to 134 ms; a
`while` over `codes[i]` took 163 to 165 ms; a `while` with
`String.code(text.at(j))` took 283 ms. One build plus one indexed pass (about
295 ms) costs about the same as one `at` pass, so keep the list when you scan
the same text twice or move back and forth in it, as `compiler/lexer.agc`
does.

## Loops and recursion

- Use a `while` over an index with mutable locals for a hot loop. On the
  same lexer tables it took about 3% to 6% less time than a `step(state)`
  tail-call loop with `.with` (29.2 vs 31.0 ms, 1,664 vs 1,741, 910 vs 939,
  771 vs 815) [PR #255].
- A call replaces the caller's frame only when it is `return f(...)` to a
  user function. Mutual recursion works that way: `is_even(1000000)`,
  where each function ends in `return` of the other, ran [measured].

```ruby
def is_even(n: Int) -> Bool
  if n == 0
    return true
  end
  return is_odd(n - 1)
end
```

- Any other call takes a frame, and a task may nest 10,000 calls. Non-tail
  `return 1 + count_down(n - 1)` ran at depth 9,000 and failed with
  `RUNTIME-STACK-OVERFLOW` at 20,000 [measured]. A builtin call is not a
  tail call either [docs/grammar/06b-builtins.md].
- The parsers stop at 1,000 levels with `PARSE-TOO-DEEP` (`src/parser.rkt`,
  `compiler/parse_base.agc`). A pass that recurses on a tree manages about
  9,900 levels and fails near 10,800 [docs/future/35-self-hosting.md]. For
  deeper input, loop with a `List` as an explicit stack.

## Struct updates

`value.with(field: x)` copies the struct in one instruction. Time for 1M
updates in a `while` loop, in ms (so also ns per update) [bench]:

| Struct and update | Constructor | `.with` |
|---|---:|---:|
| 2 fields, 1 changed | 197 | 212 |
| 4 fields, 1 changed | 289 | 240 |
| 8 fields, 1 changed | 380 | 280 |
| 16 fields, 1 changed | 567 | 373 |
| 8 fields, `step(s.with(...))` tail call | 570 | 485 |

Use `.with` for structs of 4 or more fields; for 2 fields `.with` is about 8%
slower than the constructor [bench]. `.with` of 2 of 6 fields costs about
220 ns against about 55 ns for a function call [PR #255], so do it once per
token or node, not per character.

## Collections

Costs as documented in [docs/grammar/06b-builtins.md] and
[docs/grammar/06-semantics.md]:

- `xs = xs.push(x)` takes near constant time, so n pushes are O(n).
- `concat` is O(b) only when the right list has at most 32 items; otherwise
  it is O(a + b). Do not `concat` a large list inside a loop.
- `xs[i]`, `List.at` and `List.set` take O(log32 n): at most four steps at
  a million items.
- `reverse`, `take` and `drop` are O(n) in the size of the result.
- `Map.put` and `Map.get` take O(log32 n). `Set.include?` and `Set.add`
  take effectively constant time. `Map.delete` and `Set.delete` are O(n),
  so deleting in a loop is O(n²).
- `Set.new` of 1M Ints took 10.9 s [measured, one run]. Most builtins run to
  the end of their turn: the scheduler switches tasks only between callbacks
  of the resumable ones (`map`, `filter`, `reduce`, `each`, `any?`, `all?`,
  `sort_by`), never inside the rest [docs/vm/10-io-scheduler.md]. Keep sets
  that size out of code other tasks wait on.
- `String.at` and `String.slice` count characters. On ASCII text each is
  O(1). On text with multi-byte characters each call walks from the nearest
  of the start, the end or the last position used [vm/strings.c], so forward
  scans are cheap and random access can cost O(n).
