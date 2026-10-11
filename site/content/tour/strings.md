---
title: Strings and interpolation
weight: 3
description: String literals, escapes, interpolation and string methods.
---

## String literals

Strings use double quotes. They hold Unicode text.

```agentica
def main() -> Void
  puts("hello")
  puts("say \"hi\"")
  puts("tab:\there")
  puts("two\nlines")
end
```

```output
hello
say "hi"
tab:	here
two
lines
```

The escapes are `\"`, `\\`, `\#`, `\n`, `\r` and `\t`.

## Interpolation

`#{...}` puts the value of an expression into a string.

```agentica
def main() -> Void
  name = "Ana"
  n = 3
  puts("Hello, #{name}!")
  puts("#{n} + 1 = #{n + 1}")
end
```

```output
Hello, Ana!
3 + 1 = 4
```

Any value with `to_s` works, and it shows the same text as `puts`:

```agentica
def main() -> Void
  puts("list: #{[1, 2]}, ok: #{true}, none: #{nil}")
end
```

```output
list: [1, 2], ok: true, none: nil
```

Write `\#{` to get the characters `#{` without interpolation:

```agentica
def main() -> Void
  puts("literal \#{name}")
end
```

```output
literal #{name}
```

## Joining strings

`+` joins two strings. Both sides must be strings.

```agentica
def main() -> Void
  first = "Ada"
  puts(first + " " + "Lovelace")
end
```

```output
Ada Lovelace
```

## Methods

Strings have many methods. A method without arguments needs no parentheses.

```agentica
def main() -> Void
  text = "  Hello, World  "
  clean = text.strip
  puts(clean)
  puts(clean.upcase)
  puts(clean.downcase)
  puts(clean.length)
  puts(clean.include?("World"))
  puts(clean.replace("World", "Agentica"))
end
```

```output
Hello, World
HELLO, WORLD
hello, world
12
true
Hello, Agentica
```

Methods can be chained:

```agentica
def main() -> Void
  words = " a b  c ".strip.split(" ")
  puts(words)
  puts(words.join("-"))
end
```

```output
["a", "b", "", "c"]
a-b--c
```

Every method is also a function in the `String` module: `s.upcase` is the same
as `String.upcase(s)`. See the [String library page](/library/string/) for the
full list.

## Comparing strings

`==` and `!=` compare text. `<` and `>` work on numbers only.

```agentica
def main() -> Void
  puts("abc" == "abc")
  puts("abc" != "abd")
end
```

```output
true
true
```

## Characters

A string cannot be indexed with `[i]`. Use `at` for one character, and `code`
and `String.from_code` to move between characters and numbers.

```agentica
def main() -> Void
  word = "café"
  puts(word.at(3))
  puts("A".code)
  puts(String.from_code(66))
  puts(word.split(""))
end
```

```output
é
65
B
["c", "a", "f", "é"]
```
