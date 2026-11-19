---
title: Pruebas
weight: 6
description: Pruebas unitarias y archivos de características Gherkin, ambos ejecutados por agentica test, y el perfil.
source_hash: "33729807a2ad"
---

`agentica test` ejecuta los dos tipos de prueba en un solo informe.

- Usa [Test](/library/testing/test/) para las pruebas unitarias: un archivo `*_test.agc` con aserciones que devuelven un `Result`.
- Usa [BDD](/library/testing/bdd/) para los archivos de características en Gherkin. Cada escenario inicia tu programa como un proceso aparte, le envía una entrada y comprueba su salida.
- Usa [Perfil](/library/testing/profile/) para medir secciones de un programa, sujetar el código a un presupuesto de pasos, y escribir la entrada para los gráficos de llamas.

## Cobertura {#coverage}

```sh
agentica test --coverage
```

`--coverage` escribe la cobertura por líneas de la ejecución en `coverage/lcov.info` en formato LCOV, que leen Codecov, Coveralls, genhtml y las extensiones de editor. Después de los totales imprime la ruta del informe, una línea por cada archivo con las líneas que se ejecutaron, y el total:

```text
coverage: coverage/lcov.info
  src/shapes.agc 4/6 lines (66.6%)
  total 4/6 lines (66.6%)
```

Cada archivo de prueba y cada escenario se ejecuta con [`--coverage FILE`](/cli/#options), y el ejecutor de pruebas suma sus cantidades. Así que el informe cuenta lo que cuenta esa opción: tus archivos y los paquetes que se leen en su lugar, no `std/` ni los paquetes descargados.

- Los archivos de prueba y los programas de pasos de la ejecución quedan fuera, pero los módulos auxiliares que importan sí se cuentan. Un programa que inicia un paso, como el de "the Agentica program", no se cuenta.
- Los archivos van en orden de nombre y las líneas en orden de línea, así que `--jobs` no cambia el informe. Las cantidades suman el trabajo de cada tarea, así que un programa cuyo trabajo no depende del orden de sus tareas obtiene las mismas cantidades con cualquier `--schedulers`.
- Una ejecución con pruebas que fallan sigue escribiendo el informe, y conserva el código de salida de las pruebas.
- Un archivo de prueba detenido por su tiempo de espera no suma nada. Una parte que no es LCOV se deja fuera y se nombra después del resumen. Ninguna de las dos cosas cambia el código de salida, a menos que todas las partes estén dañadas (abajo).
- Cuando no hay ninguna parte, como en una ejecución sin pruebas, no se escribe nada y un `coverage/lcov.info` antiguo se queda.
- Un informe que no se puede escribir, por ejemplo cuando `coverage` es un archivo, o unas partes todas dañadas, hacen fallar una ejecución cuyas pruebas pasaron, con código de salida 1 y una línea `RUNTIME-INTERNAL` (el código que da `--coverage FILE`), así que el CI no sube un informe antiguo.
- El nuevo informe reemplaza un `coverage/lcov.info` antiguo en un solo paso, así que quien lo lee nunca ve la mitad (por encima de 16 MiB, el antiguo se quita antes).

Con `--json`, el informe tiene un objeto `coverage`. `lines` cuenta las líneas con código y `hit` las que se ejecutaron. `path` es `null` cuando no se escribió ningún informe. `broken` lista las partes que se dejaron fuera, cada una como `{"part", "message"}`, y `problem` es `{"code", "message"}` cuando el informe no se pudo escribir o las partes no se pudieron listar o estaban todas dañadas, o `null`:

```json
{"path": "coverage/lcov.info", "lines": 6, "hit": 4, "files": [{"file": "src/shapes.agc", "lines": 6, "hit": 4}], "broken": [], "problem": null}
```
