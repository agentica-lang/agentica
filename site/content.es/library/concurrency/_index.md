---
title: Concurrencia
weight: 4
description: Ejecuta trabajo al mismo tiempo con tareas, pasa valores entre tareas con canales, comparte estado en tablas ATS, guarda texto calculado en una caché y mantén estado en actores.
source_hash: "c29a3ba6848d"
---

Las tareas son ligeras y se ejecutan en los planificadores de la VM, uno por núcleo lógico de forma predeterminada, así que usan varios núcleos de CPU y se solapan mientras esperan E/S o un temporizador. Su orden no está fijo; `--schedulers 1` ejecuta una tarea a la vez. La página del tour [Tareas](/tour/tasks/) es un inicio breve.

- Usa [Task](/library/concurrency/task/) para ejecutar trabajo al mismo tiempo: iniciar, esperar, pausar y cancelar tareas.
- Usa un [Channel](/library/concurrency/channel/) para pasar valores entre tareas. Un productor envía y un consumidor recibe.
- Usa una tabla [ATS](/library/concurrency/ats/) para compartir un contador o una caché que las tareas actualizan en el mismo sitio.
- Usa [Cache](/library/concurrency/cache/) (`std/cache`) para guardar texto calculado que comparten las tareas, dentro de un presupuesto de bytes.
- Usa un [Actor](/library/concurrency/actor/) (`std/actor`) para un estado que una tarea posee y que otras tareas alcanzan con `cast` y `call`.
- Usa un [Supervisor](/library/concurrency/supervisor/) (`std/supervisor`) para iniciar actores y reiniciar uno que falla.
