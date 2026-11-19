---
title: Perfil
weight: 3
description: Mide secciones de un programa en pasos y en tiempo, cuenta los pasos de una tarea y escribe la entrada para los gráficos de llamas.
source_hash: "0c2ef488c2a6"
---

`System.Profile` es un miembro integrado de `System`; no necesita importación. `System.Profile.measure` da nombre a una sección de un programa para el perfil, y `System.Profile.steps` cuenta los pasos de la tarea en ejecución. Ambos funcionan igual tanto si el perfil está activado como si está desactivado, así que pueden quedarse en el código.

Los pasos son la unidad de trabajo de la VM: lo que cuenta `--max-steps`. Se repiten exactamente de una ejecución a otra, así que son los números que conviene comparar. El tiempo de reloj cambia con la máquina y su carga.

## System.Profile.measure {#systemprofilemeasure}

```signature
System.Profile.measure(label: String, block: Fn[T]) -> T
```

Ejecuta el bloque una vez y devuelve su valor. El bloque no toma parámetros; un valor de función sin parámetros también sirve (`System.Profile.measure("load", &load)`).

```agentica
def total(n: Int) -> Int
  sum = 0
  for k in 0...n
    sum += k
  end

  sum
end

def main() -> Void
  t = System.Profile.measure("total") do total(1000) end
  puts(t)
end
```

```output
499500
```

Un bloque que usa `try` da un `Result`. Dale a la llamada un tipo `Result`, para que el bloque sepa que da uno:

```agentica
def parse(text: String) -> Result[Int]
  n = try text.to_i
  ok(n)
end

def main() -> Void
  r: Result[Int] = System.Profile.measure("parse") do
    a = try parse("12")
    b = try parse("30")
    ok(a + b)
  end

  puts(r.unwrap_or(0))
end
```

```output
42
```

Sin el perfil, una medida es una llamada al bloque: un paso y el trabajo propio del bloque. Con el perfil activado (abajo), cada etiqueta obtiene una fila `section`:

- `calls`: cuántas veces se ejecutó una medida de la etiqueta.
- `steps`, `us`, `gc_ms`: los pasos de la tarea, el tiempo de reloj en microsegundos y el tiempo del recolector de basura en milisegundos, desde el inicio del bloque hasta su final.

Las secciones son inclusivas: una sección contiene las secciones anidadas en ella, así que `outer` de abajo cuenta también los pasos de ambas llamadas a `inner`. Una etiqueta que se ejecuta dentro de sí misma en la misma tarea (recursión) cuenta cada llamada, pero sus pasos y su tiempo solo una vez, para la llamada más externa. Los pasos son los de la tarea que ejecuta la medida, así que una medida en una tarea cuenta solo los pasos de esa tarea; el tiempo es tiempo de reloj, y sigue corriendo mientras la tarea espera. Una medida cuyo bloque termina en un error de runtime o en una cancelación cuenta como una llamada sin pasos.

```agentica
def work(n: Int) -> Int
  sum = 0
  i = 0
  while i < n
    sum += i
    i += 1
  end

  sum
end

def main() -> Void
  both = System.Profile.measure("outer") do
    a = System.Profile.measure("inner") do work(100) end
    b = System.Profile.measure("inner") do work(200) end
    a + b
  end

  puts(both)
end
```

```output
24850
```

## System.Profile.steps {#systemprofilesteps}

```signature
System.Profile.steps() -> Int
```

Los pasos que la tarea en ejecución ha ejecutado hasta ahora. La cantidad es la misma en cada ejecución del mismo trabajo, con o sin perfil, así que una prueba puede limitar el código a un presupuesto de pasos. Cada tarea tiene su propia cantidad.

```agentica
def work(n: Int) -> Int
  sum = 0
  for k in 0...n
    sum += k
  end

  sum
end

def cost(n: Int) -> Int
  before = System.Profile.steps()
  work(n)
  System.Profile.steps() - before
end

def main() -> Void
  puts(cost(100) == cost(100))
  puts(cost(200) > cost(100))
end
```

```output
true
true
```

## El informe del perfil {#the-profile-report}

Define `AGENTICA_VM_TRACE=profile` para obtener un informe en stderr al terminar la ejecución (`AGENTICA_VM_TRACE_FILE=PATH` lo escribe en un archivo). Después de las filas de funciones, archivos e integrados, aparecen hasta 30 filas `section`, con más pasos primero:

```text
AGENTICA_VM_TRACE=profile agentica sections.agc
...
agc-trace +0.004012 profile section calls=1 steps=2241 us=33 gc_ms=0 name=outer
agc-trace +0.004015 profile section calls=2 steps=2228 us=31 gc_ms=0 name=inner
```

`agentica FILE.agc` imprime dos informes, primero el del front end y luego el del programa; las secciones están en el del programa.

Un programa que llama a un [módulo nativo](/library/io-and-system/native/modules/) también obtiene una fila `native` por cada función del módulo que se ejecutó, como `native calls=2 us=48 mode=dirty name=crunch module=demo`: sus llamadas, los microsegundos gastados en C, y si es una función de tipo short o dirty.

El informe termina con lo que ejecutó la VM, para trabajar en la propia VM: una línea `events` (instrucciones, recargas de frame y cómo fueron las llamadas a integrados), una fila `op` por cada opcode con su parte de las instrucciones, y las 20 filas `pair` más comunes de dos opcodes ejecutados uno tras otro.

Una ejecución guarda hasta 4096 etiquetas. Cada etiqueta posterior cuenta en una única sección `[overflow]` (el frame `measure[overflow]` en las pilas plegadas), así que una etiqueta creada a partir de datos, como `"item #{i}"`, no puede hacer crecer el perfil sin límite.

## Un archivo por cada proceso {#one-file-for-each-process}

Una ejecución de pruebas inicia muchas VM (el front end, el ejecutor de pruebas, cada archivo de prueba, el programa bajo prueba), y todas reciben el mismo entorno, así que todas añaden datos al mismo `AGENTICA_VM_TRACE_FILE`. Escribe `{pid}` en el nombre del archivo y cada proceso lo reemplaza por su propio identificador de proceso, así que cada uno escribe un archivo propio:

```text
AGENTICA_VM_TRACE=profile AGENTICA_PROFILE_FORMAT=folded AGENTICA_VM_TRACE_FILE=/tmp/suite-{pid}.folded agentica test
ls /tmp/suite-*.folded
```

Cada `{pid}` del nombre se reemplaza, por muchos que sean, y el patrón sirve para cada categoría de traza y para el informe, igual que para las pilas plegadas. Un nombre de 4096 bytes o más después del reemplazo no se puede abrir, y la traza queda desactivada, como con cualquier otro archivo que no se puede abrir. El archivo se abre en modo de añadido, así que un proceso que reutiliza un pid añade al archivo antiguo: usa un directorio vacío para cada ejecución. [`agentica test --timing`](/cli/) muestra qué archivos y escenarios son lentos, así que sabes qué archivos conviene leer.

## Gráficos de llamas {#flame-graphs}

Añade `AGENTICA_PROFILE_FORMAT=folded` al perfil para obtener pilas plegadas en lugar del informe: una línea por cada pila distinta, con los frames desde el más externo hacia dentro, separados por `;`, luego un espacio y el peso en pasos. flamegraph.pl, inferno y speedscope leen este formato.

```text
AGENTICA_VM_TRACE=profile AGENTICA_PROFILE_FORMAT=folded AGENTICA_VM_TRACE_FILE=app.folded agentica app.agc
flamegraph.pl app.folded > app.svg
inferno-flamegraph app.folded > app.svg
```

Un archivo tiene este aspecto:

```text
main@app.agc:25;measure:outer;block@app.agc:27:32;measure:inner;block@app.agc:28:34;work@app.agc:1 1000
main@app.agc:25;Int.times;block@app.agc:40:11 1000
```

- Una función es `name@FILE:LINE`, un bloque `block@FILE:LINE:COL`, una lambda `lambda@FILE:LINE:COL`, un bucle o callback nativo (`Int.times`, `List.map`) el nombre de su integrado, y un `System.Profile.measure` es `measure:LABEL`.
- La VM toma una muestra de la pila de la tarea en ejecución cada 1000 pasos, cada una con un peso de 1000. `AGENTICA_PROFILE_SAMPLE=N` fija N (de 1 a 1.000.000.000); `AGENTICA_PROFILE_SAMPLE=1` cuenta cada paso, y entonces los pesos suman los `steps` del informe.
- El muestreo cuenta pasos, no tiempo, así que el archivo es el mismo en cada ejecución del mismo programa, en cualquier sistema. No hay peso de tiempo, ya que cambiaría de una ejecución a otra.
- Las pilas de más de 512 frames conservan las mitades externa e interna alrededor de un frame `...`. Un `;`, un `%` o un carácter de control en un nombre se escribe como `%XX` (`%3B`, `%25`), así que dos pilas distintas nunca comparten una línea.
- El archivo guarda hasta 1.048.576 pilas distintas (y 256 MiB de frames). Pasado eso, el peso de cada pila nueva va a una única línea `[truncated]` al final, y le sigue una línea `agc-trace folded profile full`.
- Usa `AGENTICA_VM_TRACE_FILE`: en stderr, las líneas se mezclan con lo que el programa escribe allí. Con `agentica FILE.agc`, el archivo tiene solo las pilas del programa; `agentica check FILE.agc` escribe las del front end.

## perf en Linux {#linux-perf}

El perfil cuenta pasos. Para ver a dónde va el tiempo de CPU, ejecuta el programa bajo `perf` de Linux con `AGENTICA_PERF_MAP=1`: el JIT escribe entonces `/tmp/perf-PID.map`, una línea por cada función que compila, y `perf report` muestra esas funciones por nombre (`agentica:NAME`) en lugar de direcciones `[JIT]` sin nombre. El mapa está desactivado de forma predeterminada y no cuesta nada cuando está apagado; el archivo queda después de la ejecución, así que quítalo cuando termines.

```text
AGENTICA_PERF_MAP=1 perf record -g agentica app.agc
perf report
```

## Notas de rendimiento {#performance-notes}

- Con el perfil apagado, `System.Profile.steps` es una llamada a un integrado; deja `System.Profile.measure` y `System.Profile.steps` en el código.
- El perfil cuenta cada paso y cada instrucción, y mide el tiempo de cada llamada a un integrado, así que una ejecución con perfil es más lenta, sobre todo en un bucle de llamadas baratas a integrados, como los métodos de String. La salida plegada añade más, cuanto más a menudo muestrea.
- Ordena por pasos; usa `us` para comparar integrados y secciones en una misma ejecución, y mide el tiempo del programa sin el perfil.
- El perfil funciona con un planificador: una ejecución con perfil usa uno, a menos que `--schedulers` o `AGENTICA_SCHEDULERS` pidan más, y en ese caso se rechaza.
