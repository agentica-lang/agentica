---
title: Test
weight: 1
description: Pruebas unitarias al estilo de ExUnit, con aserciones que devuelven un Result.
source_hash: "b238ece601bd"
---

`Test` es un módulo integrado para pruebas unitarias; no necesita importación. Un archivo de prueba es un programa cuyo `main` llama a `Test.run` con una lista de pruebas. Cada prueba devuelve `Result[Void]`, y también cada aserción, así que `try` detiene una prueba en su primera aserción fallida. Agentica no tiene excepciones.

```agentica {mode="check"}
def parse_port(text: String) -> Result[Int]
  n = try text.strip.to_i
  return error("port out of range: #{n}") if n < 1 or n > 65535

  ok(n)
end

def main() -> Void
  Test.run([
    Test.test("parses a port") do
      try Test.eq(parse_port("8080"), ok(8080))
      Test.eq(parse_port(" 80 "), ok(80))
    end,
    Test.test("rejects zero") do Test.error?(parse_port("0")) end,
    Test.test("ports are below 65536") do Test.assert(parse_port("65536").ok? == false, "65536 must be rejected") end,
  ])
end
```

Un archivo `*_test.agc` también puede no tener `main`. Entonces sus funciones de nivel superior cuyo nombre empieza por `test_` son sus pruebas, en el orden del código fuente, como si `main` pasara `Test.test("name", &test_name)` por cada una a `Test.run`. Una prueba se nombra como su función, sin `test_` y con cada `_` convertido en un espacio, y se informa en su `def`. El resto del archivo son funciones auxiliares, tipos e importaciones.

```agentica {mode="check"}
def parse_port(text: String) -> Result[Int]
  n = try text.strip.to_i
  return error("port out of range: #{n}") if n < 1 or n > 65535

  ok(n)
end

def test_parses_a_port() -> Result[Void]
  try Test.eq(parse_port("8080"), ok(8080))
  Test.eq(parse_port(" 80 "), ok(80))
end

def test_rejects_zero() -> Result[Void] = Test.error?(parse_port("0"))
```

Un archivo con `main` y funciones `test_` a la vez es `CHECK-TEST-MAIN`, así que un `main` olvidado nunca oculta pruebas; con la forma de `main`, nombra los auxiliares sin el prefijo `test_`. Sin `main`, una función de prueba no toma parámetros y su resultado se escribe `Result[Void]` (un alias de tipo de él no cuenta); cualquier otra cosa es `CHECK-TEST-SIGNATURE`, y una función que se llama solo `test_` es `CHECK-TEST-NAME`. `agentica check` aplica estas reglas a los archivos `*_test.agc`. Ejecutado como programa normal, un archivo de prueba sin `main` es `CHECK-MAIN`; en un archivo de cualquier otro nombre, las funciones `test_` son funciones normales.

`Test` es un nombre reservado, con el miembro `Test.Case`. `IO.inspect` de un `Test.Case` muestra `<Test.Case>`.

## Test.test {#testtest}

```signature
Test.test(name: String, body: Fn[Result[Void]]) -> Test.Case
```

Crea una prueba a partir de un nombre y un bloque. Un `Test.Case` guarda el nombre, el bloque y el lugar de la llamada, que es donde se informa de la prueba. Los nombres no deben estar vacíos y deben ser únicos dentro de un archivo; si no, `Test.run` falla con `RUNTIME-TEST-NAME` en esa llamada.

## Test.run {#testrun}

```signature
Test.run(tests: List[Test.Case]) -> Void
```

Sirve al ejecutor de pruebas y nunca devuelve. Llámala desde el propio `main`: dentro de una prueba o de cualquier otra tarea falla con `RUNTIME-TEST-RUN` en la llamada ("call Test.run from main, outside every test").

Con `agentica test`, el ejecutor de pruebas habla con el archivo por un canal propio (véase [Process](/library/io-and-system/process/)). La entrada y la salida estándar de una prueba son suyas: `IO.gets` devuelve el error de fin de entrada, y todo lo que imprime la prueba, incluso una línea que parece un registro, es solo salida, que se muestra bajo una prueba fallida. Una prueba no debe llamar a `Process.parent_read_line` ni a `Process.parent_send`; pertenecen al ejecutor de pruebas, y nada impide que una prueba rompa el protocolo. Un archivo que llama a `Test.run` con los argumentos de `agentica test` pero sin ese canal falla con `RUNTIME-TEST-RUN`.

- Nombra el archivo `*_test.agc`. `agentica test` encuentra esos archivos en `test/` de forma predeterminada e imprime una línea por prueba: `PASS file / name`, o `FAIL file / name` con el diagnóstico y la salida de la prueba debajo.
- Cada prueba se ejecuta en su propia tarea, así que un fallo solo hace fallar esa prueba. Cada prueba tiene 30 segundos (`RUNTIME-TEST-TIMEOUT`), y `main` tiene 30 segundos para llegar a `Test.run` (un error de archivo con el mismo código). Una prueba que termina, alcanza su límite de pasos o agota su tiempo de espera termina la ejecución del archivo, y las pruebas posteriores quedan como `NOT RUN`.
- Un archivo se ejecuta con `--max-steps` de 1.000.000 por el número de pruebas que ejecuta, más uno, compartido por todas sus pruebas, así que `--only` lo reduce; `System.Profile.steps` mide una prueba. `agentica test --max-steps N` cambia el 1.000.000 por `N` (un entero positivo), y `--max-steps unlimited` quita el límite; un escenario de un archivo `.feature` recibe lo mismo por cada uno de sus pasos, más uno, con o sin `--isolate`.
- Un archivo que termina, falla o nunca llama a `Test.run` es un error de archivo que muestra lo que imprimió.
- Una prueba que agota el tiempo conserva la salida que imprimió, hasta 1 MiB. Una prueba que imprime más de 1 MiB falla de inmediato con `RUNTIME-BDD-OUTPUT-LIMIT`, incluso si nunca termina, y no muestra salida.
- Ejecutado como programa normal, el archivo imprime `run this file with agentica test` en stderr y termina con código 2.

Una prueba falla con el primero de estos que se aplique:

- el fallo de su tarea (`RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-UNWRAP-ERROR`, ...), en el fallo; el informe muestra la pila de llamadas, como lo hace una detención normal;
- su primera aserción fallida (`RUNTIME-TEST-ASSERTION`), con los valores esperado y real;
- el `error(message)` que devolvió su bloque (`RUNTIME-TEST-ERROR`), en la prueba;
- las tareas que inició y dejó en ejecución (`RUNTIME-TEST-PENDING-TASKS`), que se detienen antes de la siguiente prueba;
- un fallo de una tarea que inició y que ninguna espera observó (`RUNTIME-TASK-CRASHED`).

Un fallo fuera de cualquier prueba, como uno en una tarea que `main` inició y que nadie esperó, hace fallar el archivo entero. Después del registro, cada fallo de las tareas de la prueba cuenta como observado, y sus tareas en ejecución se cancelan antes de la siguiente prueba. Los errores que terminan la ejecución (un error de runtime en `main`, `RUNTIME-STEP-LIMIT`, un error interno de la VM, `System.exit`) siguen terminando la ejecución entera, también desde una prueba.

Cada prueba tiene su propio generador aleatorio, sembrado a partir de la semilla de la ejecución y del nombre de la prueba, así que una prueba ve los mismos valores de `Random` sola o con las demás.

## Test.eq {#testeq}

```signature
Test.eq(actual: T, expected: T) -> Result[Void]
```

Compara dos valores del mismo tipo. El tipo sale del primer argumento, así que pon primero el valor real: `Test.eq(r, error("x"))` funciona, pero `Test.eq(error("x"), r)` es `CHECK-RESULT-TYPE`, porque `error("x")` no dice cuál es su tipo `ok`. El tipo debe tener igualdad: `Int`, `Float`, `Bool`, `String`, `Nil`, `Range`, `JSON.Value`, y listas, mapas, conjuntos, Results (también `Result[Void]`), estructuras y enums formados por ellos. Las funciones, las tareas, los handles y dos tipos distintos son `CHECK-TYPE-MISMATCH`. Las listas se comparan en orden; los mapas por clave y los conjuntos por elemento, en cualquier orden; las estructuras y los enums por tipo, variante y campos, y los Float según IEEE 754. Un `JSON.Value` se compara como lo hace `==`: las claves de objeto en cualquier orden y los números por valor, a cualquier profundidad.

```agentica
struct Point
  x: Int
  y: Int
end

def main() -> Void
  puts(Test.eq(Point(x: 1, y: 2), Point(x: 1, y: 2)))
  puts(Test.eq({"a": 1, "b": 2}, {"b": 2, "a": 1}))
  puts(Test.eq([1, 2], [1, 3]))
end
```

```output
ok()
ok()
error("expected [1, 3]; actual [1, 2]", kind: "test.failed")
```

Cuando los valores difieren, la prueba informa `values are not equal`, y el texto del error es `expected E; actual A`, con ambos valores en la forma de `inspect`, salvo que un `JSON.Value` es su texto JSON y un `Bytes` es texto entre comillas: el ASCII imprimible tal cual, y los demás bytes escapados como en un `String` (`\e`, `\xFF`), mostrando los primeros 32 bytes (`<Bytes 7 "+OK\r\n\x00\xFF">`). `Test.ok?` da `expected ok; actual A`, `Test.error?` da `expected an error; actual A`, y `Test.assert` da su mensaje. Se informa del primer fallo registrado de una prueba, y `RUNTIME-TEST-ASSERTION` lleva `expected` y `actual` para `Test.eq`, solo `actual` para `Test.ok?` y `Test.error?`, y ninguno para `Test.assert`.

Una aserción fallida cuenta contra la prueba en la que se ejecuta (su propia tarea, o una tarea iniciada dentro de ella), aunque no se use su resultado, así que `_ = Test.eq(a, b)` sigue haciendo fallar la prueba. Un Result descartado es `CHECK-UNUSED-RESULT`: pon `try` delante de una aserción que vaya seguida de otra sentencia, y deja la última aserción de un bloque de prueba sin él. Fuera de una prueba, una aserción solo devuelve su resultado.

## Test.ok? {#testok}

```signature
Test.ok?(result: Result[T]) -> Result[Void]
```

Comprueba que un `Result` es `ok`.

```agentica
def main() -> Void
  puts(Test.ok?("12".to_i))
  puts(Test.ok?("x".to_i).message)
end
```

```output
ok()
expected ok; actual error("cannot convert \"x\" to Int", kind: "number.parse")
```

## Test.error? {#testerror}

```signature
Test.error?(result: Result[T]) -> Result[Void]
```

Comprueba que un `Result` es un error.

```agentica
def main() -> Void
  puts(Test.error?("x".to_i))
  puts(Test.error?("0".to_i).message)
end
```

```output
ok()
expected an error; actual ok(0)
```

## Test.assert {#testassert}

```signature
Test.assert(condition: Bool, message: String) -> Result[Void]
```

Comprueba una condición; un fallo lleva el mensaje.

```agentica
def main() -> Void
  puts(Test.assert(1 < 2, "one is below two"))
  puts(Test.assert(2 < 1, "two is below one").message)
end
```

```output
ok()
two is below one
```
