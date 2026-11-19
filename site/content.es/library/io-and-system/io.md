---
title: IO
weight: 1
description: Imprime en la salida estándar y en el error estándar, y lee la entrada estándar.
source_hash: "be39e611176d"
---

Se pueden llamar `puts`, `print`, `gets` y `gets!` sin el prefijo `IO.`.

En Linux, macOS y Windows:

- Una impresión llega a una tubería o a un archivo sin `IO.flush()`. La VM la escribe en cuanto el lector la toma.
- Las lecturas de la entrada estándar y las escrituras en la salida o en el error estándar esperan sin detener otras tareas.
- Cada flujo guarda hasta 64 KiB. Cuando una tubería está llena, las tareas que imprimen esperan su turno, en orden. Una impresión no tiene tiempo de espera, y una impresión nunca se mezcla con otra (tampoco un mensaje de fallo).
- La salida y el error estándar que van a la misma terminal o al mismo archivo (por ejemplo con `2>&1`) comparten un búfer, así que `puts` e `IO.warn` mantienen su orden. En Windows esto se cumple cuando ambos descriptores son el mismo objeto handle.
- Un programa cuya salida o error estándar pierde a su lector (`prog | head`) termina en silencio con código de salida 141, como hace una herramienta Unix al recibir SIGPIPE; otros errores de escritura lo terminan con `RUNTIME-INTERNAL`.
- En Windows, el texto que se escribe en una consola llega al programa como UTF-8, sea cual sea la página de códigos de la consola.
- En Windows, después de una señal de parada y para los últimos mensajes de error, una tubería o una consola tiene en total una espera de hasta 200 ms. Así, un lector que nunca lee no puede retrasar el fin del programa.

En otros sistemas, la salida se guarda en búfer, así que llama a `IO.flush()` cuando otro programa espere tu salida línea a línea. Una lectura de la entrada estándar bloquea todo el programa hasta que llega la entrada. Una escritura en la salida o en el error estándar lo bloquea hasta que el lector toma el texto.

## puts {#puts}

```signature
puts(value: T) -> Void
IO.puts(value: T) -> Void
```

Imprime un valor y un salto de línea. Las cadenas se imprimen tal como son. Los demás valores se imprimen como en la interpolación.

```agentica
def main() -> Void
  puts("text")
  IO.puts([1, 2])
end
```

```output
text
[1, 2]
```

## print {#print}

```signature
print(value: T) -> Void
IO.print(value: T) -> Void
```

Imprime sin salto de línea.

```agentica
def main() -> Void
  print("a")
  print("b")
  puts("")
end
```

```output
ab
```

## IO.warn {#iowarn}

```signature
IO.warn(value: T) -> Void
```

Imprime un valor y un salto de línea en el error estándar, no en la salida estándar. Úsalo para los registros.

```agentica
def main() -> Void
  IO.warn("this goes to stderr")
  puts("this goes to stdout")
end
```

```output
this goes to stdout
```

## IO.inspect {#ioinspect}

```signature
IO.inspect(value: T) -> T
```

Imprime la forma de depuración de un valor y devuelve el mismo valor.

```agentica
def main() -> Void
  name = IO.inspect("Ana")
  puts(name.length)
end
```

```output
"Ana"
3
```

## gets {#gets}

```signature
gets() -> Result[String]
IO.gets() -> Result[String]
```

Lee una línea, sin su terminador (LF, CR o CRLF). Al final de la entrada devuelve un resultado de error. Una línea vacía es `ok("")`.

```agentica
def main() -> Void
  first = gets()
  puts(first)
  second = gets()
  puts(second.ok?)
end
```

```input
hello
```

```output
ok("hello")
false
```

## gets! {#gets-1}

```signature
gets!() -> String
IO.gets!() -> String
```

Lee una línea. Al llegar al final de la entrada detiene el programa con `RUNTIME-END-OF-INPUT`. Puede quitar sus paréntesis.

```agentica
def main() -> Void
  name = gets!.strip
  puts("Hello, #{name}!")
end
```

```input
  Ana
```

```output
Hello, Ana!
```

## IO.eof? {#ioeof}

```signature
IO.eof?() -> Bool
```

Indica si la entrada ha terminado. Mira sin consumir, y puede bloquearse hasta que llegue un dato o el final de la entrada. Las lecturas no tienen tiempo de espera, y el presupuesto de pasos no puede interrumpir la E/S bloqueante.

```agentica
def main() -> Void
  count = 0
  while !IO.eof?
    _line = IO.gets!
    count += 1
  end

  puts("#{count} lines")
end
```

```input
a
b
c
```

```output
3 lines
```

## IO.read {#ioread}

```signature
IO.read() -> String
```

Lee todo lo que queda de la entrada, hasta el final. No puede leer un solo mensaje de un peer que mantiene abierta la entrada estándar.

```agentica
def main() -> Void
  text = IO.read()
  puts(text.split("\n"))
end
```

```input
one
two
```

```output
["one", "two", ""]
```

La última línea termina con `\n`, así que `split` da una última parte vacía.

## IO.read_bytes {#ioread_bytes}

```signature
IO.read_bytes(count: Int) -> Result[Bytes]
```

Espera exactamente `count` bytes o el final de la entrada, y los devuelve como un [`Bytes`](/library/data-structures/bytes/) sin decodificar. `count` va de 0 a 1048576; cero devuelve bytes vacíos sin consumir la entrada. Al final de la entrada los bytes están vacíos.

Las lecturas de texto y las de bytes comparten una misma entrada. Los bytes que toma una no los ve la otra.

```agentica
def main() -> Void
  bytes = IO.read_bytes(2).unwrap!
  puts(bytes.to_a)
  puts(String.from_bytes(bytes))
end
```

```input
hi
```

```output
[104, 105]
ok("hi")
```

## IO.flush {#ioflush}

```signature
IO.flush() -> Void
```

Vacía ahora la salida estándar en búfer (el error estándar no se vacía). En Linux, macOS y Windows, la tarea espera hasta que la salida haya llegado a la tubería o al archivo. Por eso puede esperar si el lector va lento. Si el lector ya no está, el programa termina con código de salida 141.

Un programa que habla un protocolo por la entrada y la salida estándar escribe un mensaje JSON compacto por línea, vacía el búfer después de cada respuesta y envía sus registros a `IO.warn` (el error estándar).

```agentica
def main() -> Void
  puts("ready")
  IO.flush()
end
```

```output
ready
```
