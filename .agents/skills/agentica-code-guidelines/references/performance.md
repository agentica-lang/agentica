# Performance rules

Clear code comes first: change a function for speed only when a profile shows
that it is hot, and keep the change only if the measurement improves. The
costs, the profiler and its report are in `agentica-programming`
`references/performance.md`; this file adds the bad/good code. Find the work
done for each item before you change anything: a closure called for each
character, a table built on each call, a call for each token.

## Tables built once

A table that does not depend on the arguments is a module constant.

```ruby
# bad
def vowel?(c: String) -> Bool = c == "a" or c == "e" or c == "i" or c == "o" or c == "u"
```

```ruby
# good
VOWELS = Set.new(["a", "e", "i", "o", "u"])

def vowel?(c: String) -> Bool = VOWELS.include?(c)
```

A key-to-value `if` chain is a `Map` constant read with `get`:
`NAMES.get(letter, "unknown")`.

## Strings

Build text with `push` and one `join`; `s = s + piece` in a loop copies the
text each time (quadratic).

```ruby
# bad
s = s + "ab"
```

```ruby
# good
parts = parts.push("ab")    # in the loop
return parts.join("")       # once, after it
```
