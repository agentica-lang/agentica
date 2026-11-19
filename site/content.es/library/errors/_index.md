---
title: Errores
weight: 3
description: Devuelve los fallos como valores Result y léelos.
source_hash: "81e9ac95c9d9"
---

Agentica no tiene excepciones. Una función que puede fallar devuelve un `Result`, y quien la llama lo lee.

- Usa [Result](/library/errors/result/) para construir `ok(value)` y `error(message)` y para leerlos.
- Un Result fallido guarda un [Error](/library/errors/error/): su mensaje, su clase, su código, sus detalles, su causa y su ubicación.
- Usa `try` dentro de una función que devuelve un `Result` para pasar un error a quien la llama. La página del tour [Result y try](/tour/results-and-try/) lo explica.
