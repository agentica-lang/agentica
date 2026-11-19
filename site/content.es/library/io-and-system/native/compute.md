---
title: Llamadas compute
weight: 3
description: Ejecuta una llamada larga de C en el grupo de hilos de cómputo, para que las demás tareas sigan ejecutándose.
source_hash: "beb7a323d3f8"
---

Una función declarada con `compute def` se ejecuta en el grupo de hilos de cómputo de la VM, un hilo por planificador, y la tarea llamadora espera mientras las demás tareas siguen. Úsala para una llamada que puede tardar: una consulta, una compresión, un paso de un modelo.

```agentica {mode="check"}
extern "libsqlite3.so.0"
  ## Sleeps for ms milliseconds off the scheduler.
  compute def sqlite3_sleep(ms: C.Int32) -> C.Int32
end

def main() -> Void
  sleeper = Task.spawn(&sqlite3_sleep, 200)
  puts("main goes on")
  puts(Task.await(sleeper))
end
```

- El resultado es el valor simple de C, como en `def`. Un `compute def` es público como cualquier otro, salvo que el bloque vaya después de `private`.
- Nada detiene una llamada compute a mitad: no tiene tiempo de espera, y `--max-steps` no la termina. Para ponerle un límite, ejecuta la llamada en una tarea y usa `Task.await(task, ms)`. Una cancelación omite una llamada que no ha empezado; una llamada en marcha sigue, la tarea cancelada deja de esperar de inmediato, y el resultado se descarta. El programa no espera a una llamada en marcha al final.
- Una llamada que nunca vuelve retiene un hilo del grupo durante el resto de la ejecución. Cuando se atascan tantas de estas llamadas como indica `--schedulers`, cada llamada compute posterior espera.
- Los argumentos se copian antes de la llamada, y un resultado `C.String` al volver. La función se ejecuta en otro hilo, así que debe ser segura para llamarse desde uno, o ejecutarse bajo un [`Native.Mutex`](/library/io-and-system/native/#running).
