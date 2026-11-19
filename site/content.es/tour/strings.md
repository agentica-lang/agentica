---
title: Cadenas e interpolación
weight: 3
description: Literales de cadena, escapes, interpolación y métodos.
source_hash: "d454a9bda6a7"
---

## Literales de cadena {#string-literals}

Las cadenas usan comillas dobles. Guardan texto Unicode.

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

Los escapes son `\"`, `\\`, `\#`, `\n`, `\r` y `\t`.

## Interpolación {#interpolation}

`#{...}` pone el valor de una expresión dentro de una cadena.

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

Cualquier valor con `to_s` sirve, y muestra el mismo texto que `puts`:

```agentica
def main() -> Void
  puts("list: #{[1, 2]}, ok: #{true}, none: #{nil}")
end
```

```output
list: [1, 2], ok: true, none: nil
```

Escribe `\#{` para obtener los caracteres `#{` sin interpolación:

```agentica
def main() -> Void
  puts("literal \#{name}")
end
```

```output
literal #{name}
```

## Heredocs {#heredocs}

Un texto de dos o más líneas es un heredoc: `<<~NAME`, las líneas del texto, y una última línea que solo contiene `NAME`. Se quita la sangría común, así que el texto puede seguir la sangría del código.

```agentica
def main() -> Void
  name = "tool"
  text = <<~TEXT
    Usage: #{name} [options]

      --verbose   print more
    Exit code 0 on success.
  TEXT
  print(text)
end
```

```output
Usage: tool [options]

  --verbose   print more
Exit code 0 on success.
```

Un heredoc es una cadena: los escapes y `#{...}` funcionan, una `"` no necesita escape, y cada línea termina con un salto de línea. El resto de la línea `<<~NAME` es código, así que `puts(<<~TEXT)` y `<<~TEXT.upcase` funcionan.

Hacen falta dos o más líneas de texto (`LEX-HEREDOC-ONE-LINE`; escribe una sola línea como `"text\n"`). Sangra con espacios: un tabulador es `LEX-HEREDOC-INDENT`. Un heredoc no puede ser un patrón de `case` ni una ruta de `import`.

## Unir cadenas {#joining-strings}

`+` une dos cadenas. Los dos lados deben ser cadenas. `*` repite una cadena: `"ab" * 3` es `"ababab"`.

```agentica
def main() -> Void
  first = "Ada"
  puts(first + " " + "Lovelace")
end
```

```output
Ada Lovelace
```

## Métodos {#methods}

Las cadenas tienen muchos métodos. Un método sin argumentos no necesita paréntesis.

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

Los métodos se pueden encadenar:

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

Cada método es también una función del módulo `String`: `s.upcase` es lo mismo que `String.upcase(s)`. Consulta la [página de la biblioteca String](/library/text-and-data/string/) para ver la lista completa.

## Comparar cadenas {#comparing-strings}

`==` y `!=` comparan texto. `<` y `>` solo funcionan con números.

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

## Caracteres {#characters}

No se puede indexar una cadena con `[i]`. Usa `at` para un carácter, y `code` y `String.from_code` para pasar de caracteres a números y al revés.

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
