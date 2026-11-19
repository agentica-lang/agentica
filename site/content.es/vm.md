---
title: La VM Aurora
weight: 7
description: Cómo ejecuta Agentica tu programa, la VM de bytecode Aurora y las bibliotecas sobre las que está construida.
source_hash: "9868f111cad2"
---

Cada programa se ejecuta en Aurora, una VM de bytecode escrita en C11. La VM forma parte del binario `agentica`; los archivos de bytecode terminan en `.agcb`.

## Del código fuente al bytecode {#from-source-to-bytecode}

El binario `agentica` tiene dos partes. El front end (el analizador léxico, el parser, el enlazador de módulos, el comprobador y el lowering), escrito en Agentica y compilado a bytecode, pasa el programa ya comprobado como bytecode en memoria a la VM, que lo ejecuta en un runtime nuevo dentro del mismo proceso. Tú puedes ejecutar los pasos por tu cuenta (opciones: [Línea de comandos](/cli/#options)):

```sh
agentica compile file.agc -o file.agcb   # write bytecode
agentica run -- file.agcb                # run it; `run` must be the first word
```

El bytecode solo se ejecuta en la VM de la misma versión de Agentica.

## Dentro de la VM {#inside-the-vm}

- **Valores.** Los valores nunca cambian en su lugar; los handles (tareas, canales, archivos, sockets, procesos) guardan el único estado mutable.
- **Cargador.** Un archivo `.agcb` no es de confianza. El cargador lo comprueba todo antes de que se ejecute nada (versión, cadenas, índices, registros, destinos de salto, una comprobación de pasos en cada bucle y en cada función que hace llamadas). Un archivo de más de 256 MiB da `agentica run: cannot read <file>`; cualquier otro archivo incorrecto da `agentica run: invalid bytecode: <reason>`. Ambos terminan con el código de salida 2.
- **Intérprete.** Un solo bucle ejecuta las instrucciones. Las llamadas apilan frames en la pila propia de la tarea. Una llamada en cola (`return f(...)` a una función de usuario) reutiliza el frame.
- **Tareas.** Las tareas se ejecutan por turnos de 2000 pasos en hilos `--schedulers N` (de forma predeterminada, uno por núcleo lógico), así que un bucle que no para no deja sin turno a las demás.
- **E/S y esperas.** Una llamada bloqueante (archivo, socket, `Task.sleep`) aparca solo su propia tarea. Cada salida a un flujo va a un búfer de 64 KiB, así que un lector lento solo frena a las tareas que escriben en la salida. El vaciado al final de la ejecución espera como máximo 30 s de forma predeterminada (`--flush-timeout`). Un `Channel.send` o `recv` en espera aparca su tarea hasta que haya un valor o un hueco listo. Un `Task.await` con tiempo límite espera a la tarea y a un temporizador; lo que despierte primero decide.
- **JIT.** Un JIT para x86-64 (Linux, macOS y Windows) y para arm64 (Linux y macOS), activado de forma predeterminada ([`--jit`](/cli/#options)), compila las funciones calientes con bucles y las funciones pequeñas sin bucle que llaman. La aritmética, las lecturas, las operaciones de texto y los saltos compatibles se ejecutan como código máquina. Otras máquinas usan el intérprete.
- **Límites.** Los pasos y la memoria no tienen límite, a menos que pongas `--max-steps` o `--max-heap` ([Opciones](/cli/#options)). Las llamadas se anidan como máximo 10 000 niveles por tarea; después, `RUNTIME-STACK-OVERFLOW` con la pila de llamadas (una función repetida, en una línea y con su cuenta). Una llamada en cola no añade profundidad.
- **Mapas y listas.** `Map` es un HAMT persistente que conserva el orden de inserción; `Map.put` copia solo la ruta hasta su clave. `List` es un vector persistente de 32 hijos por nodo, más una cola pequeña: indexar toma como máximo cuatro pasos para un millón de elementos, añadir n elementos cuesta O(n), y una lista de solo Ints o solo Floats ocupa 8 bytes por elemento. `take`, `drop` y `reverse` son O(n), y `sort` es O(n log n).
- **JSON.** Cada objeto conserva el orden de sus claves: los campos de una estructura, el orden de inserción de un mapa y el orden del texto de un objeto analizado, donde una clave repetida conserva su primer lugar y su último valor.
- **Módulos estándar.** Los módulos de `std/` están escritos en Agentica, incrustados en el binario y enlazados a tu bytecode como tus propios módulos.

## Sobre qué está construida {#what-it-is-built-on}

Son submódulos de git fijados en `vm/third_party/`, todos compilados en el binario de la release, que no necesita más biblioteca del sistema que la biblioteca C. Un `make` predeterminado en Linux enlaza en su lugar el OpenSSL 3, libgc y zlib del sistema (ver [Primeros pasos](/getting-started/)). Los archivos de la release incluyen los avisos de licencia en `licenses/`.

| Biblioteca | Para qué sirve | Licencia |
|---|---|---|
| Boehm GC (bdwgc) | Recolector de basura de los valores del programa | Licencia Boehm-GC (permisiva) |
| yyjson | Lee el texto JSON para `JSON.parse` | MIT |
| libuv | Bucle de eventos, E/S de archivos y sockets, temporizadores, procesos y el grupo de hilos | MIT, con partes BSD-2-Clause e ISC |
| OpenSSL 3.5 | TLS para `TLS.connect`, `TLS.listen` y HTTPS | Apache-2.0 |
| picohttpparser | Analiza las líneas de inicio y las cabeceras HTTP | MIT (doble licencia MIT o Perl) |
| libffi | Llama a funciones C de los bloques `extern` (Linux, macOS y Windows x64) | MIT |
| zlib | Códec DEFLATE, zlib y gzip para `Zlib` | Licencia zlib |

Las tablas de Unicode (conversión de mayúsculas y minúsculas, caracteres imprimibles) se generan desde la Unicode Character Database y se guardan en el código fuente de la VM, bajo la Unicode License v3.
