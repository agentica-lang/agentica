---
title: Tareas
weight: 15
description: Ejecuta trabajo a la vez con tareas ligeras.
source_hash: "e80b0cd8706c"
---

## Iniciar una tarea {#start-a-task}

`Task.spawn` inicia una función en una tarea ligera, con un argumento, o sin ninguno para una función que no tiene parámetros. `Task.await` espera a que termine y entrega el resultado.

```agentica
def square(n: Int) -> Int = n * n

def main() -> Void
  task = Task.spawn(&square, 7)
  puts(Task.await(task))
end
```

```output
49
```

El tipo es `Task[R]`, donde `R` es el tipo del resultado de la función.

## Muchas tareas {#many-tasks}

Inicia todas las tareas y luego espera. Avanzan al mismo tiempo, lo que ayuda con los archivos y con la red.

```agentica
def slow_double(n: Int) -> Int
  Task.sleep(10)
  n * 2
end

def main() -> Void
  tasks = [1, 2, 3].map do |n| Task.spawn(&slow_double, n) end
  results = tasks.map do |t| Task.await(t) end
  puts(results)
end
```

```output
[2, 4, 6]
```

## Muchos elementos, unos pocos a la vez {#many-items-a-few-at-a-time}

`Task.map(items, limit, timeout_ms, f)` ejecuta una función para cada elemento, como máximo `limit` a la vez. Da un `Result` por elemento, en orden. Un elemento que tarda más que `timeout_ms` recibe `error("task: timed out")`, y los demás siguen. Úsalo para trabajo que espera, como las solicitudes HTTP. Consulta [Task.map](/library/concurrency/task/#taskmap) para las reglas y un ejemplo.

## Más de un argumento {#more-than-one-argument}

Una función de tarea recibe un solo argumento. Pasa una estructura para enviar varios valores:

```agentica
struct Job
  name: String
  times: Int
end

def run(job: Job) -> String = "#{job.name.upcase} x#{job.times}"

def main() -> Void
  t = Task.spawn(&run, Job(name: "go", times: 2))
  puts(Task.await(t))
end
```

```output
GO x2
```

## Pausar {#sleep}

`Task.sleep(ms)` pausa la tarea actual. `Task.sleep(0)` deja correr a las demás tareas.

```agentica
def main() -> Void
  start = Time.monotonic_ms()
  Task.sleep(20)
  puts(Time.monotonic_ms() - start >= 20)
end
```

```output
true
```

## Esperar con tiempo de espera {#wait-with-a-timeout}

`Task.await(task, timeout_ms)` espera como máximo esos milisegundos, y entrega `Await.Done(value)` o `Await.TimedOut`. La tarea sigue en marcha. Consulta [Task.await con tiempo de espera](/library/concurrency/task/#taskawait-with-a-timeout).

## Reglas {#rules}

- Una tarea que no es `main` y que falla se detiene sola: su error se imprime, sus tareas hijas se cancelan, y sus archivos y sockets se cierran. Esperarla da `error` si devuelve un `Result`; si no, detiene a quien espera. Un fallo sin esperar hace que el programa termine con código 1.
- Un archivo, socket, listener o proceso pertenece a la tarea que lo abrió y se cierra cuando esa tarea termina. `Task.spawn_owning` le pasa uno (o un `Channel`) a la nueva tarea.
- Cuando `main` termina, las tareas en marcha se cancelan. Espera lo que necesites.
- Las tareas corren en varios núcleos de CPU (`--schedulers 1` las ejecuta de una en una). La salida puede llegar en cualquier orden. Para pasar valores entre tareas, usa un [Channel](/library/concurrency/channel/).

Consulta [Task](/library/concurrency/task/) y [Channel](/library/concurrency/channel/) para la referencia.
