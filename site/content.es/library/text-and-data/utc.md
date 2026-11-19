---
title: UTC (std)
weight: 14
description: El módulo std/utc, que convierte milisegundos de Unix en la fecha y la hora civiles en UTC y en texto RFC 3339.
source_hash: "b16daf1e196c"
---

**Obsoleto:** usa en su lugar las [fechas y horas](/library/io-and-system/time/) integradas de `Time`; `std/utc` se quita en la versión 0.36.0. `UTC.iso8601(ms, 3)` pasa a ser `Time.at_us(ms * 1000).unwrap!.iso8601` (seis dígitos de fracción, años de 1 a 9999), y `UTC.parts(ms)` pasa a ser los campos de ese `Time.DateTime`.

`std/utc` está escrito en Agentica: `import UTC from "std/utc"`. Lee el número de milisegundos desde la época Unix, el valor de `Time.now_ms()`, y devuelve una fecha y una hora del día en UTC. El nombre `Time` pertenece al integrado, así que el módulo tiene otro nombre. `iso8601` es el `Time#utc.iso8601(n)` de Ruby, y los campos de `parts` son los de `Time#utc` (`year`, `month`, `day`, `hour`, `min`, `sec`, con los nombres escritos completos). El calendario es el gregoriano proléptico, la hora Unix no tiene segundos intercalares, y no hay zonas horarias: cada respuesta es UTC. Nada en él se detiene, para ningún `Int`.

```ruby
UTC.parts(time_ms: Int) -> UTC.Parts
UTC.iso8601(time_ms: Int, fraction_digits: Int = 0) -> String
```

```agentica
import UTC from "std/utc"

def main() -> Void
  ms = 1_781_261_702_345
  puts(UTC.iso8601(ms))
  puts(UTC.iso8601(ms, 3))
  puts(UTC.iso8601(-1, 3))
  p = UTC.parts(ms)
  puts("#{p.year}-#{p.month}-#{p.day} #{p.hour}:#{p.minute}:#{p.second}.#{p.millisecond}")
end
```

```output
2026-06-12T10:55:02Z
2026-06-12T10:55:02.345Z
1969-12-31T23:59:59.999Z
2026-6-12 10:55:2.345
```

## parts {#parts}

`parts` divide `time_ms` en un `UTC.Parts`, una estructura con los campos `year`, `month` (1 a 12), `day` (1 a 31), `hour` (0 a 23), `minute` (0 a 59), `second` (0 a 59) y `millisecond` (0 a 999). Un `time_ms` negativo es una hora anterior a 1970. Los años bisiestos siguen la regla gregoriana (1900 no lo es, 2000 sí).

## iso8601 {#iso8601}

`iso8601` escribe texto RFC 3339 con el desfase `Z`. Con `fraction_digits` mayor que 0 añade esa cantidad de dígitos de los segundos después de un punto, como lo hace `iso8601(n)` de Ruby. La entrada tiene milisegundos, así que los dígitos después del tercero son `0`. Ruby escribe n dígitos para cualquier n; este módulo acota: una cantidad menor que 0 se toma como 0, y una mayor que 9 como 9. Un año fuera de 0 a 9999 se escribe con su signo y con al menos cuatro dígitos (`-0001`, `10000`).
