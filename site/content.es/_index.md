---
title: Agentica
description: Agentica es Ruby con tipos estáticos. Sintaxis parecida a Ruby, comprobada antes de ejecutar, con valores inmutables.
source_hash: 5a32d41d8d0f
---

Agentica es Ruby con tipos estáticos. Tiene una sintaxis parecida a la de Ruby. Cada programa se comprueba antes de ejecutarse, y los valores nunca cambian en su lugar. El lenguaje es pequeño a propósito, para que personas y agentes de IA puedan escribir, leer y corregir programas con pocas sorpresas. Cada error tiene un código estable, una posición en el código fuente y, a menudo, una sugerencia para corregirlo.

El proyecto está alojado en [GitHub](https://github.com/agentica-lang/agentica).

{{< switcher >}}
{{< example title="Manejar errores" >}}
```agentica
def main() -> Void
  for text in ["4", "8", "x"]
    case text.to_i
      ok(n) -> puts("#{text} doubled is #{n * 2}")
      error(_) -> puts("#{text} is not a number")
    end
  end
end
```

```output
4 doubled is 8
8 doubled is 16
x is not a number
```
{{< /example >}}
{{< example title="Contar palabras" >}}
```agentica
def main() -> Void
  words = "Fun to learn, delightful to ship".downcase.replace(",", "").split(" ")
  puts(words.tally)
end
```

```output
{"fun": 1, "to": 2, "learn": 1, "delightful": 1, "ship": 1}
```
{{< /example >}}
{{< example title="Ejecutar en paralelo" >}}
```agentica
def square(n: Int) -> Int = n * n

def main() -> Void
  tasks = (1..5).map { |n| Task.spawn(&square, n) }
  puts(tasks.map { |task| Task.await(task) })
end
```

```output
[1, 4, 9, 16, 25]
```
{{< /example >}}
{{< /switcher >}}

Un programa más largo:

```agentica
# Prices are in cents, so the math stays exact.
TAX_PERCENT = 21

## Returns the price with the tax added.
def with_tax(cents: Int) -> Int = cents + (cents * TAX_PERCENT) / 100

def main() -> Void
  prices = [250, 1_000, 99]
  # Ranges include both ends: 1..3 is 1, 2, 3.
  for i in 1..prices.size
    puts("item #{i}: #{with_tax(prices[i - 1])} cents")
  end

  total = prices.map(&with_tax).sum
  puts("total: #{total} cents")
end
```

Ejecútalo con `agentica prices.agc`:

```output
item 1: 302 cents
item 2: 1210 cents
item 3: 119 cents
total: 1631 cents
```

## Siguiente lectura {#read-next}

- [Primeros pasos](/getting-started/): instala Agentica, ejecuta tu primer programa y compruébalo.
- [Tour del lenguaje](/tour/): el lenguaje en páginas cortas, una idea cada vez.
- [Línea de comandos](/cli/): cada comando, opción y caché del programa `agentica`.
- [Biblioteca](/library/): cada módulo integrado, con un ejemplo por función.
- [Especificación del lenguaje](/reference/): la gramática formal y las reglas.
- [Guía de estilo](/style/): cómo escribir código simple y fácil de leer.
- [Patrones](/patterns/): los patrones de diseño comunes en Agentica.
- [La VM Aurora](/vm/): cómo se ejecuta tu programa, y las bibliotecas que hay debajo.
