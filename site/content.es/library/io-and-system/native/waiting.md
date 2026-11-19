---
title: Esperar un descriptor
weight: 4
description: Aparca una tarea hasta que el socket o el descriptor de una biblioteca de C se pueda leer o escribir.
source_hash: "488540d60fed"
---

Muchas bibliotecas de red de C (libpq, curl multi, hiredis) tienen un modo no bloqueante: la biblioteca dice a qué socket espera, y tu programa espera. `Native.wait_readable(fd, timeout_ms)` y `Native.wait_writable(fd, timeout_ms)` aparcan la tarea hasta que el descriptor se pueda leer o escribir, mientras las demás tareas siguen. Las dos dan un `Result[Void]`.

```agentica {mode="check"}
extern "libc.so.6"
  def eventfd(initval: C.Int32, flags: C.Int32) -> C.Int32
  def eventfd_write(fd: C.Int32, value: C.Int64) -> C.Int32
end

def ring(fd: Int) -> Int
  Task.sleep(50)
  eventfd_write(fd, 1)
end

def main() -> Void
  fd = eventfd(0, 0)
  bell = Task.spawn(&ring, fd)
  puts(Native.wait_readable(fd, 1_000)) # ok() once the other task writes
  puts(Task.await(bell))
end
```

El bucle de conexión de una biblioteca espera de la misma forma, con `try Native.wait_readable(socket, 5_000)` entre sus sondeos.

- Cuando pasan `timeout_ms` (positivo), el resultado es `error("native: timed out")`. Un tiempo de espera que no es positivo, un descriptor negativo y uno que no se puede sondear (cerrado, un archivo regular, `/dev/null` en Linux) dan un error que empieza con `native: `. En macOS, `/dev/null` siempre está listo.
- Un error o una desconexión en el descriptor termina la espera con `ok`, como lo hace `poll(2)`: la siguiente llamada de la biblioteca lo informa.
- La espera vigila una copia del descriptor (una nueva apertura de su archivo, `/proc/self/fd` o `F_GETPATH` en macOS, o un duplicado para un socket, el extremo maestro de una terminal, un eventfd y una tubería de macOS), así que la biblioteca conserva su descriptor y sus flags, y dos tareas pueden esperar en un mismo descriptor.
- Si la biblioteca cierra el descriptor durante una espera, la espera sigue y termina en su tiempo de espera (`native: timed out`), a menos que el archivo quede listo.
- Una cancelación detiene la espera; el final del programa no la espera.
- En Windows solo se puede esperar un socket: el número es el `SOCKET` de Winsock de la biblioteca, vigilado a través de un socket duplicado. Eso pone el socket en modo no bloqueante para siempre, ya que Winsock no puede leer el modo de vuelta. Un handle de socket admite una espera a la vez: una segunda espera con el mismo valor de handle mientras otra espera da un error que empieza con `native: `, y el valor de un socket cerrado puede seguir ocupado hasta que termine su espera. Cualquier otro valor (un descriptor del runtime de C, un handle de archivo o de tubería) también da ese error, y también lo da un socket cerrado, normalmente (Windows reutiliza los valores de handle).
- `--deny-native` también las rechaza: un descriptor viene del código nativo.
