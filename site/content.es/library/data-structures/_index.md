---
title: Estructuras de datos
weight: 1
description: Listas, mapas, conjuntos, colas, heaps, rangos, bytes, pipelines perezosos y valores opcionales, y cuándo usar cada uno.
source_hash: "24a3703f3f17"
---

- [List](/library/data-structures/list/): valores de un tipo, en orden. Recórrelos, ordénalos, transfórmalos o filtralos.
- [Map](/library/data-structures/map/): busca un valor por clave (`Int`, `String` o `Bytes`), en orden de inserción. Búsquedas y contadores.
- [Set](/library/data-structures/set/): cada `Int`, `String` o `Bytes` una vez, en el orden en que se añadió por primera vez. Duplicados y pertenencia.
- [Queue](/library/data-structures/queue/) (`std/queue`): primero en entrar, primero en salir, de cadenas.
- [Heap](/library/data-structures/heap/) (`std/heap`): una cola de prioridad de cualquier tipo; `pop` da el primer valor según tu orden.
- [Range](/library/data-structures/range/): `0...n` cuenta sin una lista. Úsalo en `for`.
- [Bytes](/library/data-structures/bytes/): una cadena de bytes compacta e inmutable, para resúmenes criptográficos, contenidos de archivos y formatos de red. Córtala, únela o compárala.
- [Lazy](/library/data-structures/lazy/): una receta de pasos sobre una lista, un rango o una fuente sin fin, que se ejecuta un elemento a la vez.
- [Optional](/library/data-structures/optional/): `some(value)` o `none`, para un valor que puede faltar.
- [Estructuras](/tour/structs/) y [enums](/tour/enums-and-case/): campos fijos con nombre, o casos con nombre.

Todos los valores son inmutables. ¿Nunca los has usado? Lee primero las páginas del tour [Listas](/tour/lists/) y [Mapas](/tour/maps/).
