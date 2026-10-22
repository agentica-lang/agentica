---
name: agentica-programming
description: >-
  Write, check, run and repair Agentica programs (`.agc` files): a Ruby-like
  language with static types and immutable values. Use for Agentica application
  code.
---

# Agentica programming

Agentica is Ruby-like (`def`, `end`, `do |x| ... end`, `#{}`) with static types
and immutable values; a program starts at `def main() -> Void`. Not every Ruby
method exists: ask `agentica help NAME`.

Work loop: write `p.agc`, `agentica check p.agc`, run `agentica p.agc < input`.
`agentica help NAME` prints a builtin's signature (Ruby names work: `split`,
`include?`). `agentica doc std/NAME` prints the API of a std/ module (`http`,
`queue`, `binary`, `logger`, `toml`); `JSON` and `File` are builtins, so use
`agentica help JSON.parse`. A diagnostic has a stable code and a `help` line:
read it, fix it.

```ruby
def main() -> Void
  total = 0
  for line in IO.read.split("\n")
    for word in line.strip.split(" ")
      if word != ""
        total += word.to_i!
      end
    end
  end
  puts("sum: #{total}")
end
```

## Gotchas

- `case x` arms are `pattern -> stmt`, ending with `_ ->` unless an enum case
  lists every variant (else `CHECK-UNREACHABLE-CASE-ARM`); no `when`, `match`,
  `let`, `;`, `continue` (`next`) or `loop do` (`while true`).
- A blank line follows every `end` of a `def`, `struct`, `enum`. The top level
  holds only declarations, in this order: `NAME = 1` constants, `struct` and
  `enum`, then `def`s.
- A non-Void `def` needs `return` on every path; the last expression is not
  returned.
- Values never change: `xs = xs.push(1)`, `m = m.put(k, v)`; a bare
  `m.put(k, v)` is `CHECK-UNUSED-VALUE`.
- A block cannot assign an outer variable; use `reduce` or a `for` loop.
- No Int/Float mixing: `n.to_f * price`. `<` is for numbers; Strings use
  `a.compare(b) < 0`; `==` only on Int, Float, Bool, String, Nil.
- Strings are not indexable: `s.at(i)`, `s.split("")` for the characters,
  `"0123456789".include?(c)` for a digit.
- `[]` and `{}` need a type: `out: List[String] = []`.
- `try` only in a `def` that returns `Result[T]`, never in `main`:
  `n = try s.to_i`, not `try s.to_i!`.
- `s.to_i` is a `Result`. `s.to_i!` halts on any bad text
  (`RUNTIME-INVALID-NUMBER`), e.g. `""` or `"abc"`: use `case s.to_i` with
  `ok(n)` / `error(m)` when input may be bad.
- `split` keeps empty parts and `split(" ")` does not split on newlines: split
  on `"\n"` first, skip `""` words.
- `ok` and `error` are builtins: do not name a variable or parameter so.
- A Result has `unwrap!`, `unwrap_or(d)`, `case`; no `value!` or `ok!`.
- Input: `IO.gets` is a `Result` (end of input is an error), `IO.read` is all
  of stdin; there is no `IO.lines`.
- `xs[i]`, `s.at(i)` and `s.slice` halt out of range; Int overflow halts.
- Build a struct with every field named: `Item(name: "a", price: 3)`.
