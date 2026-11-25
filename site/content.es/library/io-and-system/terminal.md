---
title: Terminal
weight: 10
description: Si un flujo es una terminal, el modo raw, el tamaño de la terminal y sus cambios de tamaño.
source_hash: "200807a8f3f5"
---

Un programa de pantalla completa (un editor, una TUI) lee las teclas de una en una y dibuja con secuencias de escape VT. `Terminal` le da lo que necesita del sistema, igual en Linux, macOS y Windows 10 o posterior. Las teclas se siguen leyendo con [`IO.read_bytes`](/library/io-and-system/io/) en la entrada estándar: llegan como bytes, y el programa (o su biblioteca) analiza las secuencias de escape de las teclas, del ratón y del texto pegado.

```agentica {mode="check"}
def main() -> Void
  Terminal.raw().unwrap!
  resized = System.subscribe([System.Signal.Winch]).unwrap!
  size = Terminal.size().unwrap!
  puts("#{size.rows}x#{size.cols}, q quits")
  IO.flush()
  while true
    if resized.recv(0).ok?
      size = Terminal.size().unwrap!
      puts("resized to #{size.rows}x#{size.cols}")
      IO.flush()
    end

    key = IO.read_bytes(1).unwrap!
    break if key.empty? or key.to_a == [113]
  end

  Terminal.raw(on: false).unwrap!
end
```

## Terminal.tty? {#terminaltty}

```signature
Terminal.tty?(stream: Terminal.Stream) -> Bool
```

Si un flujo estándar es una terminal (en Windows, una consola). `Terminal.Stream` es un enum: `Stdin`, `Stdout` y `Stderr`. Un pipe, un archivo y `/dev/null` no son terminales.

```agentica
def main() -> Void
  puts(Terminal.tty?(Terminal.Stream.Stdout))
end
```

```output
false
```

## Terminal.raw {#terminalraw}

```signature
Terminal.raw(on: Bool = true) -> Result[Void]
```

Pone la terminal de la entrada estándar en modo raw, como hace `IO#raw` de Ruby: lo que se escribe no se muestra, cada tecla llega enseguida (sin edición de línea, sin esperar a Enter) y las teclas que envían señales no las envían: Ctrl-C llega como el byte 3 y Ctrl-Z como 26. La salida sigue igual: `"\n"` empieza una línea nueva en la primera columna. `Terminal.raw(on: false)` devuelve el modo que la terminal tenía antes del primer `Terminal.raw`.

- En Windows apaga la entrada por líneas, el eco y el evento Ctrl-C de la consola, y enciende la entrada VT (las teclas llegan como las mismas secuencias de escape que en Linux y macOS) y la salida VT.
- La VM devuelve el primer modo cuando el programa termina: al terminar con normalidad, con `System.exit`, con un error en tiempo de ejecución y con una señal de parada como `Term`, así que un fallo no deja el shell en modo raw. Un `kill -9` no se puede capturar: ejecuta entonces `stty sane`.
- Cuando la entrada estándar no es una terminal devuelve un error con la clase `io.failed` y el número de error del sistema como código. `Terminal.raw(on: false)` cuando el modo raw no está activo devuelve `ok`.
- El modo pertenece a la terminal, no a una tarea: una llamada vale para todas las tareas.

```agentica
def main() -> Void
  case Terminal.raw()
    ok(_) -> puts("raw")
    error(e) -> puts(e.kind)
  end

  puts(Terminal.raw(on: false).ok?)
end
```

```output
io.failed
true
```

## Terminal.size {#terminalsize}

```signature
Terminal.size() -> Result[Terminal.Size]
```

El tamaño de la terminal de la salida estándar, o del error estándar cuando la salida estándar no es una terminal, como `Terminal.Size(rows: Int, cols: Int)`. En Windows es el tamaño de la ventana de la consola. Cuando ninguno de los dos flujos es una terminal devuelve un error con la clase `io.failed`.

```agentica
def main() -> Void
  case Terminal.size()
    ok(size) -> puts("#{size.rows}x#{size.cols}")
    error(e) -> puts(e.kind)
  end
end
```

```output
io.failed
```

## Cambios de tamaño {#resize-events}

Un cambio de tamaño de la terminal es la señal `System.Signal.Winch`, que [`System.subscribe`](/library/io-and-system/system/#systemsubscribe) entrega en un canal. Lee el tamaño nuevo con `Terminal.size` cuando llega un valor. Sin una suscripción, un cambio de tamaño no hace nada.

- En Linux y macOS es `SIGWINCH`, que el sistema envía a los programas del trabajo en primer plano de la terminal.
- En Windows la VM la recibe cuando libuv ve que la consola cambia de tamaño; `Winch` es la única señal a la que un programa de Windows puede suscribirse.
