---
title: Fechas y horas
weight: 9
description: Fechas del calendario, horas del día y fechas con hora con un desfase fijo respecto de UTC, como valores comprobados de la familia Time, con tiempo Unix, tiempo de reloj, aritmética, texto ISO 8601 y strftime.
source_hash: "bdaee3a9927a"
---

La familia `Time` tiene cuatro tipos de registro. Sus campos son `Int`s, con los nombres de `Time` en Ruby:

- `Time.Date`: un día del calendario (`year`, `month`, `day`).
- `Time.TimeOfDay`: una hora del reloj sin fecha ni desfase (`hour`, `min`, `sec`, `usec`).
- `Time.NaiveDateTime`: una fecha y una hora del reloj sin desfase, así que no nombra ningún instante (`year`, `month`, `day`, `hour`, `min`, `sec`, `usec`).
- `Time.DateTime`: una fecha y una hora del reloj con un desfase fijo respecto de UTC, así que nombra un solo instante (los campos de `Time.NaiveDateTime`, y después `utc_offset`, en segundos al este de UTC).

El calendario es el gregoriano proléptico, con los años 1 a 9999. La precisión es de microsegundos (`usec`, de 0 a 999999). El tiempo Unix no tiene segundos intercalares, así que un `sec` de 60 es un error. Un desfase es un número entero de minutos, de `-86340` (`-23:59`) a `86340` (`+23:59`); no hay zonas horarias con nombre ni horario de verano. Los campos de un `Time.DateTime` son la hora en ese desfase.

Cada valor es válido, porque solo los integrados que siguen crean uno: escribir `Time.Date(year: ..., ...)` o `d.with(...)` es `CHECK-NOT-CONSTRUCTIBLE`. `JSON.encode` y `JSON.decode` rechazan estos tipos, solos o dentro de una estructura (`CHECK-NOT-ENCODABLE`, `CHECK-NOT-DECODABLE`). `==` compara un `Time.Date`, un `Time.TimeOfDay` o un `Time.NaiveDateTime` campo por campo. Un `Time.DateTime` no tiene `==` (`CHECK-TYPE-MISMATCH`): dos lecturas de un mismo instante con desfases distintos tienen campos distintos, así que compara instantes con `Time.compare(a, b) == 0`. `Test.eq` sí compara dos de ellos campo por campo, así que una prueba afirma la hora exacta.

Un integrado que toma uno de estos valores como primer argumento se escribe como su método: `t.to_i`, `t.getlocal(3600)`. Sin argumentos, los paréntesis son opcionales, como en un campo.

`Time.now` lee el tiempo de reloj; los demás relojes están en [System, Time y Random](/library/io-and-system/system/).

## Time.Date.new {#timedatenew}

```signature
Time.Date.new(year: Int, month: Int, day: Int) -> Result[Time.Date]
```

La fecha, o un error de clase `argument` cuando no es un día real: un año fuera de 1 a 9999, un mes fuera de 1 a 12, o un día que el mes no tiene.

```agentica
def main() -> Void
  d = Time.Date.new(2024, 2, 29).unwrap!
  puts("#{d.year} #{d.month} #{d.day}")
  puts(Time.Date.new(2026, 2, 29).message)
end
```

```output
2024 2 29
day 29 is not valid for month 2 of year 2026
```

## Time.TimeOfDay.new {#timetimeofdaynew}

```signature
Time.TimeOfDay.new(hour: Int, min: Int, sec: Int, usec: Int) -> Result[Time.TimeOfDay]
```

La hora del reloj, o un error de clase `argument` para una hora fuera de 0 a 23, un minuto o un segundo fuera de 0 a 59, o un `usec` fuera de 0 a 999999.

```agentica
def main() -> Void
  puts(Time.TimeOfDay.new(7, 32, 0, 999999))
  puts(Time.TimeOfDay.new(23, 59, 60, 0).message)
end
```

```output
ok(Time.TimeOfDay(hour: 7, min: 32, sec: 0, usec: 999999))
sec 60 is a leap second, which is not supported
```

## Time.NaiveDateTime.new {#timenaivedatetimenew}

```signature
Time.NaiveDateTime.new(year: Int, month: Int, day: Int, hour: Int, min: Int, sec: Int, usec: Int) -> Result[Time.NaiveDateTime]
```

La fecha y la hora, con las comprobaciones de `Time.Date.new` y `Time.TimeOfDay.new`.

```agentica
def main() -> Void
  t = Time.NaiveDateTime.new(2026, 10, 14, 19, 5, 42, 201337).unwrap!
  puts("#{t.day} #{t.hour}:#{t.min}")
end
```

```output
14 19:5
```

## Time.DateTime.new {#timedatetimenew}

```signature
Time.DateTime.new(year: Int, month: Int, day: Int, hour: Int, min: Int, sec: Int, usec: Int, utc_offset: Int) -> Result[Time.DateTime]
```

La hora en `utc_offset` segundos al este de UTC, con las comprobaciones de `Time.NaiveDateTime.new`, y un error de clase `argument` para un desfase que no sea un número entero de minutos o que esté fuera de `-86340` a `86340`.

```agentica
def main() -> Void
  t = Time.DateTime.new(2026, 10, 14, 21, 5, 42, 201337, 7200).unwrap!
  puts("#{t.hour} #{t.utc_offset}")
  puts(Time.DateTime.new(2026, 10, 14, 21, 5, 42, 0, 30).message)
end
```

```output
21 7200
utc_offset 30 is not a whole number of minutes
```

## Time.Date.leap? {#timedateleap}

```signature
Time.Date.leap?(year: Int) -> Bool
```

Si el año tiene 366 días: divisible entre 4, y no entre 100 salvo que también lo sea entre 400. Admite cualquier `Int`.

```agentica
def main() -> Void
  puts([1900, 2000, 2024, 2026].map do |year| Time.Date.leap?(year) end)
end
```

```output
[false, true, true, false]
```

## Time.Date.days_in_month {#timedatedays_in_month}

```signature
Time.Date.days_in_month(year: Int, month: Int) -> Result[Int]
```

La cantidad de días del mes, de 28 a 31, o un error de clase `argument` para un año fuera de 1 a 9999 o un mes fuera de 1 a 12.

```agentica
def main() -> Void
  puts(Time.Date.days_in_month(2024, 2))
  puts(Time.Date.days_in_month(2026, 13).message)
end
```

```output
ok(29)
month 13 is not in 1..12
```

## Time.at y Time.at_us {#timeat-and-timeat_us}

```signature
Time.at(seconds: Int) -> Result[Time.DateTime]
Time.at_us(us: Int) -> Result[Time.DateTime]
```

El instante `seconds` (o `us` microsegundos) después de la época Unix, 1970-01-01T00:00:00Z, en UTC (`utc_offset` 0). Una cantidad negativa es anterior a 1970. El rango va de `-62135596800` a `253402300799` segundos (de `-62135596800000000` a `253402300799999999` microsegundos), el primer y el último instante de los años 1 a 9999; una cantidad fuera de él es un error de clase `argument`.

```agentica
def main() -> Void
  puts(Time.at(1_000_000_000).unwrap!)
  puts(Time.at_us(-1).unwrap!)
  puts(Time.at(253402300800).message)
end
```

```output
Time.DateTime(year: 2001, month: 9, day: 9, hour: 1, min: 46, sec: 40, usec: 0, utc_offset: 0)
Time.DateTime(year: 1969, month: 12, day: 31, hour: 23, min: 59, sec: 59, usec: 999999, utc_offset: 0)
seconds 253402300800 is not in -62135596800..253402300799
```

## Time.now {#timenow}

```signature
Time.now() -> Time.DateTime
```

El tiempo de reloj en UTC, hasta el microsegundo. El tiempo de reloj puede saltar, así que mide una duración con `Time.monotonic_ms` o `Time.monotonic_ns`.

```agentica
def main() -> Void
  puts(Time.now().utc_offset)
end
```

```output
0
```

## to_i y to_us {#to_i-and-to_us}

```signature
Time.DateTime.to_i(time: Time.DateTime) -> Int
Time.DateTime.to_us(time: Time.DateTime) -> Int
```

El instante como segundos (`to_i`) o microsegundos (`to_us`) desde la época Unix, sea cual sea el desfase. `to_i` redondea hacia menos infinito, como lo hace `Time#to_i` de Ruby: el microsegundo anterior a la época cae en el segundo `-1`. Ninguno falla; una lectura en el año 1 o 9999 con un desfase puede dar un instante justo fuera del rango de `Time.at`.

```agentica
def main() -> Void
  t = Time.DateTime.new(2001, 9, 9, 3, 46, 40, 500000, 7200).unwrap!
  puts("#{t.to_i} #{t.to_us}")
  puts(Time.at_us(-1).unwrap!.to_i)
end
```

```output
1000000000 1000000000500000
-1
```

## getutc y getlocal {#getutc-and-getlocal}

```signature
Time.DateTime.getutc(time: Time.DateTime) -> Result[Time.DateTime]
Time.DateTime.getlocal(time: Time.DateTime, utc_offset: Int) -> Result[Time.DateTime]
```

El mismo instante leído con desfase 0 (`getutc`) o con `utc_offset` segundos al este de UTC (`getlocal`). Un error de clase `argument` cuando el desfase no es uno que acepta `Time.DateTime.new`, o cuando la lectura nueva queda fuera de los años 1 a 9999.

```agentica
def main() -> Void
  t = Time.DateTime.new(2026, 10, 14, 21, 5, 42, 0, 7200).unwrap!
  puts(t.getutc.unwrap!.hour)
  puts(t.getlocal(-18000).unwrap!.hour)
  puts(t.getlocal(30).message)
end
```

```output
19
14
utc_offset 30 is not a whole number of minutes
```

## naive_of y assume_offset {#naive_of-and-assume_offset}

```signature
Time.DateTime.naive_of(time: Time.DateTime) -> Time.NaiveDateTime
Time.NaiveDateTime.assume_offset(naive: Time.NaiveDateTime, utc_offset: Int) -> Result[Time.DateTime]
```

`naive_of` conserva la lectura y quita el desfase. `assume_offset` da un desfase a una lectura sin desfase, lo que la convierte en un instante; conserva los campos, así que su único error (de clase `argument`) es un desfase que `Time.DateTime.new` rechaza.

```agentica
def main() -> Void
  n = Time.NaiveDateTime.new(2026, 10, 14, 9, 0, 0, 0).unwrap!
  t = n.assume_offset(-18000).unwrap!
  puts(t.to_i)
  puts(t.naive_of == n)
end
```

```output
1791986400
true
```

## to_date {#to_date}

```signature
Time.DateTime.to_date(time: Time.DateTime) -> Time.Date
Time.NaiveDateTime.to_date(naive: Time.NaiveDateTime) -> Time.Date
```

La fecha de la lectura, en su propio desfase.

```agentica
def main() -> Void
  t = Time.DateTime.new(2026, 10, 14, 23, 30, 0, 0, -3600).unwrap!
  puts(t.to_date)
  puts(t.getutc.unwrap!.to_date)
end
```

```output
Time.Date(year: 2026, month: 10, day: 14)
Time.Date(year: 2026, month: 10, day: 15)
```

## iso8601 {#iso8601}

```signature
date.iso8601() -> String
time.iso8601() -> String
naive.iso8601() -> String
```

El texto ISO 8601 de un valor de cualquiera de los cuatro tipos (`date` un `Time.Date`, `time` un `Time.TimeOfDay` o un `Time.DateTime`, `naive` un `Time.NaiveDateTime`): `YYYY-MM-DD` para una fecha, `HH:MM:SS.ffffff` para una hora del día, las dos unidas por `T` para una fecha y hora, y para un `Time.DateTime` su desfase, `Z` con desfase 0 y `+HH:MM` o `-HH:MM` en otro caso (RFC 3339). La fracción siempre tiene seis dígitos, así que los textos de un mismo desfase se ordenan como sus instantes.

```agentica
def main() -> Void
  t = Time.DateTime.new(2026, 10, 14, 21, 5, 42, 201337, 7200).unwrap!
  puts(t.iso8601)
  puts(t.getutc.unwrap!.iso8601)
  puts(t.naive_of.iso8601)
  puts(t.to_date.iso8601)
end
```

```output
2026-10-14T21:05:42.201337+02:00
2026-10-14T19:05:42.201337Z
2026-10-14T21:05:42.201337
2026-10-14
```

## Time.Date.iso8601 y los demás análisis {#timedateiso8601-and-the-other-parses}

```signature
Time.Date.iso8601(text: String) -> Result[Time.Date]
Time.TimeOfDay.iso8601(text: String) -> Result[Time.TimeOfDay]
Time.NaiveDateTime.iso8601(text: String) -> Result[Time.NaiveDateTime]
Time.DateTime.iso8601(text: String) -> Result[Time.DateTime]
```

El valor que expresa el texto en la forma que escribe `iso8601`, con las comprobaciones de `new` del tipo. Los segundos pueden no llevar fracción, o llevar un `.` con cualquier cantidad de dígitos; los dígitos después del sexto se cortan, no se redondean. `T` y `Z` pueden estar en minúscula, como permite RFC 3339, y `-00:00` es el desfase 0.

`Time.DateTime.iso8601` exige un desfase, y `Time.NaiveDateTime.iso8601` lo rechaza, así que un texto sin desfase nunca se lee como instante por error. Cualquier otro texto da un error de clase `argument` que indica qué se esperaba y en qué carácter (contando desde 1): un espacio en lugar de `T`, `+0200`, una hora de desfase mayor que 23, `07:32` sin segundos, texto después del valor, o un segundo de 60.

```agentica
def main() -> Void
  puts(Time.DateTime.iso8601("2026-10-14t19:05:42.123456789z").unwrap!.iso8601)
  puts(Time.DateTime.iso8601("2026-10-14T19:05:42").message)
  puts(Time.DateTime.iso8601("2026-10-14 19:05:42Z").message)
  puts(Time.NaiveDateTime.iso8601("2026-10-14T19:05:42Z").message)
  puts(Time.TimeOfDay.iso8601("07:32:00.5"))
end
```

```output
2026-10-14T19:05:42.123456Z
missing offset; use Time.NaiveDateTime.iso8601 for text without one
expected YYYY-MM-DDTHH:MM:SS at character 11
offset "Z" is not allowed here; use Time.DateTime.iso8601
ok(Time.TimeOfDay(hour: 7, min: 32, sec: 0, usec: 500000))
```

## strftime {#strftime}

```signature
date.strftime(format: String) -> String
time.strftime(format: String) -> String
naive.strftime(format: String) -> String
```

El formato de un valor de cualquiera de los cuatro tipos (`date` un `Time.Date`, `time` un `Time.TimeOfDay` o un `Time.DateTime`, `naive` un `Time.NaiveDateTime`) con cada directiva sustituida por una parte del valor. Acepta un subconjunto de las directivas de `strftime` de Ruby, con nombres en inglés:

- `%Y` el año en cuatro dígitos, `%m` y `%d` el mes y el día en dos, `%j` el día del año en tres;
- `%u` el día ISO de la semana (`1` lunes a `7` domingo), `%w` el día de la semana de `0` (domingo) a `6`;
- `%a` y `%A` el nombre del día, corto (`Wed`) y completo (`Wednesday`), `%b` y `%B` el nombre del mes, corto (`Oct`) y completo (`October`);
- `%H`, `%M` y `%S` la hora, el minuto y el segundo en dos dígitos, `%L` los milisegundos en tres, `%N` los nanosegundos en nueve;
- `%z` el desfase como `+HHMM` y `%:z` como `+HH:MM`, y `%%` un `%`.

No hay flags ni anchos. Una directiva que no está en esta lista, o que nombra una parte que el valor no tiene, se queda tal como está escrita, igual que un `%` al final: por ejemplo `%e`, `%y`, `%F`, `%T` y `%-d`, `%H` de un `Time.Date` y `%z` de un `Time.NaiveDateTime`.

```agentica
def main() -> Void
  t = Time.DateTime.new(2026, 10, 14, 21, 5, 42, 201337, 7200).unwrap!
  puts(t.strftime("%a %d %b %Y %H:%M:%S.%L %:z"))
  puts(t.to_date.strftime("%A, %B %d (day %j) %H:%M"))
end
```

```output
Wed 14 Oct 2026 21:05:42.201 +02:00
Wednesday, October 14 (day 287) %H:%M
```

## add_days y add_us {#add_days-and-add_us}

```signature
date.add_days(days: Int) -> Result[Time.Date]
naive.add_days(days: Int) -> Result[Time.NaiveDateTime]
time.add_days(days: Int) -> Result[Time.DateTime]
naive.add_us(us: Int) -> Result[Time.NaiveDateTime]
time.add_us(us: Int) -> Result[Time.DateTime]
```

El valor `days` días de calendario o `us` microsegundos después, o antes si la cantidad es negativa. Un `Time.DateTime` conserva su desfase, así que su lectura y su instante se mueven juntos; con desfases fijos, cada día son 86400 segundos. Un error de clase `argument` cuando la lectura sale de los años 1 a 9999, para cualquier `Int` como cantidad: la cantidad se comprueba antes de sumarla, así que no puede desbordar. Una duración es un `Int` simple en microsegundos; no hay aritmética sobre un `Time.TimeOfDay`.

```agentica
def main() -> Void
  d = Time.Date.new(2024, 2, 28).unwrap!
  puts(d.add_days(1).unwrap!.iso8601)
  t = Time.DateTime.new(2026, 10, 14, 23, 30, 0, 0, 7200).unwrap!
  puts(t.add_us(3_600_000_000).unwrap!.iso8601)
  puts(d.add_days(9_000_000).message)
end
```

```output
2024-02-29
2026-10-15T00:30:00.000000+02:00
the date is outside the years 1 to 9999
```

## days_between y us_between {#days_between-and-us_between}

```signature
from.days_between(to: Time.Date) -> Int
from.us_between(to: Time.DateTime) -> Int
from.us_between(to: Time.NaiveDateTime) -> Int
```

La diferencia `to - from`, positiva cuando `to` es posterior: en días entre dos fechas, en microsegundos entre dos instantes (los desfases cuentan) o entre dos lecturas.

```agentica
def main() -> Void
  a = Time.DateTime.new(2026, 10, 14, 12, 0, 0, 0, 7200).unwrap!
  b = Time.DateTime.new(2026, 10, 14, 12, 0, 0, 0, 0).unwrap!
  puts(a.us_between(b))
  puts(a.naive_of.us_between(b.naive_of))
  puts(a.to_date.days_between(Time.Date.new(2027, 1, 1).unwrap!))
end
```

```output
7200000000
0
79
```

## Time.compare {#timecompare}

```signature
Time.compare(time: Time.DateTime, other: Time.DateTime) -> Int
Time.compare_naive(naive: Time.NaiveDateTime, other: Time.NaiveDateTime) -> Int
Time.compare_date(date: Time.Date, other: Time.Date) -> Int
Time.compare_time(time: Time.TimeOfDay, other: Time.TimeOfDay) -> Int
```

`-1`, `0` o `1` según el primer valor sea anterior, igual o posterior a `other`, como lo da `<=>` de Ruby. `Time.compare` compara instantes, así que un mismo instante con dos desfases da `0`; las demás comparan lecturas, días y horas del reloj.

```agentica
def main() -> Void
  a = Time.DateTime.new(2026, 10, 14, 21, 0, 0, 0, 7200).unwrap!
  puts(Time.compare(a, a.getutc.unwrap!))
  puts(Time.compare_naive(a.naive_of, a.getutc.unwrap!.naive_of))
end
```

```output
0
1
```

## cwday y yday {#cwday-and-yday}

```signature
date.cwday() -> Int
date.yday() -> Int
```

El día ISO de la semana, `1` para lunes a `7` para domingo, y el día del año, de `1` a `366`. Una fecha y hora los da mediante `to_date`.

```agentica
def main() -> Void
  d = Time.Date.new(2026, 10, 14).unwrap!
  puts("#{d.cwday} #{d.yday}")
end
```

```output
3 287
```
