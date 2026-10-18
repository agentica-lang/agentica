# Releases multiplataforma de Agentica

## Objetivo

Publicar un binario funcional para Linux x86_64, Windows x86_64, macOS
x86_64 y macOS arm64. El alcance incluye archivos, tareas, procesos y red;
no basta con producir ejecutables que enlacen pero carezcan de builtins.

Rama de trabajo: `feat/multiplatform-releases`.

Todas las casillas empiezan sin marcar. El generador de datos embebidos tiene
cambios preparados y pruebas locales de ensamblado, pero su paso no se dará
por terminado hasta que tenga las comprobaciones indicadas.

## Plataformas y entregables

| Plataforma | Runner público | Toolchain | Paquete final |
| --- | --- | --- | --- |
| Linux x86_64 | `ubuntu-latest` | Zig fijado, glibc 2.28 | `agentica-VERSION-linux-x86_64.tar.gz` |
| Windows x86_64 | `windows-2025` | GCC de MSYS2 UCRT64 | `agentica-VERSION-windows-x86_64.zip` |
| macOS Intel | `macos-15-intel` | Apple clang | `agentica-VERSION-macos-x86_64.tar.gz` |
| macOS ARM | `macos-latest` | Apple clang | `agentica-VERSION-macos-arm64.tar.gz` |

Las etiquetas de macOS se verificaron en la
[referencia oficial de runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
CI comprobará también la arquitectura del ejecutable; el nombre del runner
no será la única evidencia. El mínimo de macOS se fijará y probará antes de
publicar. El objetivo Windows será un ejecutable nativo, utilizable sin
instalar MSYS2 ni herramientas de compilación.

## Estado inicial y restricciones

- `Makefile:219` deja libuv fuera de los builds no Linux; su selección y
  enlace están en `Makefile:223` y `Makefile:309`.
- `vm/files.c:1741` deja vacías las funciones de archivos fuera de Linux.
  El compilador depende de ellas para leer fuentes y guardar bytecode.
- `vm/loop.c:824` desactiva el event loop fuera de Linux. Archivos con
  timeouts y cancelación necesitan primero este soporte compartido.
- `vm/process.c:8`, `vm/duplex.c:8`, `vm/tcp.c:8` y
  `vm/tls_openssl.c:13` contienen implementaciones protegidas para Linux.
- `vm/tools/gen-embedded.sh:1` genera actualmente datos para el enlazador;
  el trabajo preparado añade ELF, Mach-O y COFF.
- `.github/workflows/platforms.yml:1` ejecuta tests C en Windows y macOS,
  pero todavía no comprueba el producto completo ni ambos tipos de Mac.
- `.github/workflows/release.yml:13` construye solo Linux y
  `.github/workflows/release.yml:145` publica sus artefactos.

Las líneas anteriores describen la base de este plan y cambiarán al portar
el código. Cada commit debe localizar de nuevo los símbolos antes de editar.

## Forma de trabajar

- [ ] Completar los pasos en orden; dividir un paso si su diff resulta
  demasiado grande para revisarlo como una unidad.
- [ ] Cada commit debe mantener Linux funcional y verificar su propio
  contrato; no dejar seguridad o pruebas para otro commit.
- [ ] Subir cada incremento y esperar los checks pertinentes antes del
  siguiente. Consultar logs de los runners reales cuando falle.
- [ ] Mantener la lógica común y aislar solo las operaciones que dependan
  del sistema. Usar el libuv y las dependencias ya vendidas en el repo.
- [ ] Mantener las capas y las reglas de `docs/vm/14-core-invariants.md:18`:
  una forma de esperar, cancelar, agotar un timeout y cerrar un recurso.
- [ ] Añadir pocas pruebas funcionales de alto valor, con Python unittest
  y peers independientes de biblioteca estándar.
- [ ] Usar localhost, puertos asignados por el sistema, directorios
  temporales y limpieza de procesos; ninguna prueba dependerá de Internet.
- [ ] Una API que escriba o borre validará sus argumentos en la propia
  función; sus pruebas comprobarán el error y que los datos previos sigan
  intactos. Lectura y escritura de una misma forma tendrán un round trip.
- [ ] No sustituir fallos de soporte por skips generales ni implementar
  operaciones síncronas que bloqueen el scheduler para hacer pasar CI.
- [ ] Actualizar documentación y skills con el comportamiento que vaya
  quedando disponible, sin anunciar antes el soporte completo.

## Dependencias y capa de los cambios

```text
1. Datos embebidos ───────────────────────────────┐
2. Dependencias nativas → 3. Event loop → 4. Archivos básicos
                                                 ↓
                              5. Driver y compilador completo
                                                 ↓
                         6. Archivos avanzados → 7. I/O estándar
                                                 ↓
                           8. Procesos → 9. Canal privado y BDD
                                                 ↓
                              10. TCP → 11. TLS → 12. HTTP
                                                 ↓
                         13. Conformidad → 14. Release completo
```

Flujos que determinan dónde intervenir:

```text
compiler/source_file.agc:40  leer una fuente
  → vm/files.c:1337         File.open y registro del recurso
  → vm/loop.c:181           trabajo, timeout y cancelación
  → backend de archivos    operación nativa del sistema

compiler/save_file.agc:9    guardar bytecode
  → vm/files.c:1337         apertura para escritura
  → vm/files.c:1458         File.write_bytes y validación
  → vm/loop.c:181           ejecución y cierre del trabajo

vm/agentica.c:100           iniciar el front end embebido
  → vm/agentica.c:152       ejecutar el programa compilado
  → vm/launch.c:151         terminar y cerrar recursos

vm/process.c:750            crear un proceso
  → vm/duplex.c:74          adjuntar el canal privado
  → vm/loop.c:181           esperas y ciclo de vida
```

El servicio conserva validación y semántica del lenguaje; el core conserva
esperas y propiedad. Las diferencias del sistema se resuelven en el backend,
no con ramas por plataforma en el compilador Agentica.

## 1. Datos embebidos portables

Commit propuesto: `build: embed compiler data on ELF Mach-O and COFF`.

Ubicaciones: `vm/tools/gen-embedded.sh:1`, `Makefile:518`,
`Makefile:522`, `Makefile:526`, `.github/workflows/platforms.yml:1`.

- [x] Revisar los cambios preparados y conservar exactamente el layout del
  índice, los offsets, la alineación y los hashes que invalidan la caché.
- [x] Seleccionar secciones y símbolos correctos para ELF, Mach-O y COFF;
  no emitir directivas específicas de ELF en los otros formatos.
- [x] Permitir calcular SHA-256 con las herramientas disponibles en macOS.
- [x] Generar y ensamblar el objeto embebido en los cuatro runners, incluidos
  los dos Mac, sin exigir aún un compilador completo funcional.
- [x] Verificar localmente que la salida Linux sigue siendo idéntica a la
  anterior.

Cierre: objetos válidos para las cuatro arquitecturas y pruebas del índice;
el ensamblado cruzado local es una comprobación adicional, no reemplaza CI.

## 2. Dependencias y toolchains nativos

Commit propuesto: `build: enable native libuv and OpenSSL dependencies`.

Ubicaciones: `Makefile:198`, `Makefile:210`, `Makefile:219`,
`Makefile:309`, `Makefile:328`, `.github/workflows/platforms.yml:1`.

- [x] Añadir al Makefile las listas de fuentes nativas de libuv para macOS
  y Windows, manteniendo la lista Linux existente.
- [x] Mantener OpenSSL del sistema en los PR y usar OpenSSL vendorizado en
  `master`, según la regla existente del CI.
- [x] Construir y enlazar libuv con OpenSSL del sistema en los PR de macOS y
  Windows; `vm-test` pasó en ambos runners.
- [x] Confirmar el build de OpenSSL vendorizado, además del camino dinámico
  usado en los PR. La ejecución manual (run 38964146212) pasó en macOS y
  Windows.
- [x] Mantener compilaciones aisladas por modo y claves de caché que
  incluyan sistema, arquitectura, compilador, flags y commits de dependencias.
- [x] Resolver GNU make en macOS y el entorno UCRT64 en Windows sin asumir
  utilidades o rutas de Linux ni introducir MSVC como segundo toolchain; los
  jobs de `vm-test` confirman ambos entornos.
- [x] Cachear dependencias nativas y compilaciones C con claves por sistema,
  arquitectura, toolchain y fuentes; el primer guardado pasó en los tres
  runners nativos. No se repitió CI para medir hits.
- [x] Compilar probes de objeto en Linux, Windows, macOS Intel y ARM; ejecutar
  `vm-test` en Linux, Windows, macOS Intel y ARM. La comprobación de DLL/dylib
  dentro de los paquetes queda en el paso 14.

Cierre: las dependencias se construyen desde una checkout limpia y cada
runner confirma la arquitectura nativa que realmente está ejecutando.

## 3. Event loop, trabajos y cierre portable

Commit propuesto: `vm: enable the libuv scheduler across platforms`.

Ubicaciones: `vm/loop.c:28`, `vm/loop.c:181`, `vm/loop.c:380`,
`vm/loop.c:430`, `vm/loop.c:486`, `vm/loop.c:526`,
`vm/launch.c:107`, `vm/launch.c:194`, `vm/tests/loop_test.c:1`.

- [x] Compartir trabajos libuv, timers, colas de completados, referencias y
  registro de recursos; separar señales y descriptores específicos de Unix.
- [x] Definir Ctrl-C, terminación y vigilancia del padre en Windows y macOS
  con las APIs nativas necesarias y una salida con tiempo acotado.
- [x] Evitar llamadas no seguras desde manejadores de señales o consola.
- [x] Cubrir éxito, timeout, carrera con la finalización, cancelación,
  detach y cierre; ningún trabajo completará sobre memoria ya liberada.
- [x] Ejecutar los casos portables de `vm/tests/loop_test.c:1` en todos los
  runners y conservar los casos específicos de señales en su sistema.

Progreso: el scheduler y los casos de éxito, timeout y cierre pasaron en Linux,
macOS 15/26 ARM, macOS 15 Intel y Windows (run 38976311444).
La etiqueta `macos-15` usada antes también era ARM.
El cierre repite pasadas no bloqueantes para
drenar callbacks de libuv. Se añadió vigilancia del padre en macOS y manejo de
parada portable en Windows. Los manejadores POSIX ahora solo actualizan estado
atómico y despiertan el loop; la escalada ocurre con un timer. El hook local
pasa; la base pasó en todas las plataformas. Los nuevos casos de pollers
pasaron en macOS ARM (run 38977386750). La portabilidad de
descriptores para pollers queda agrupada con el backend de archivos del paso 4.

Cierre: cada recurso y trabajo se libera una sola vez, incluso al cancelar
o terminar el runtime; Linux mantiene sus checks de sanitizadores.

## 4. Archivos básicos, rutas y entorno

Commit propuesto: `vm: port basic filesystem operations and paths`.

Ubicaciones: `vm/files.c:227`, `vm/files.c:1337`, `vm/files.c:1410`,
`vm/files.c:1458`, `vm/files.c:1477`, `vm/files.c:1609`,
`vm/files.c:1670`, `vm/process.c:1040`,
`tests/test_filesystem.py:55`, `tests/test_vm_file_lines.py:1`.

- [x] Portar abrir, leer bytes y texto, escribir, append, flush y cerrar
  archivos normales; mantener límites, buffers y comprobación de tipos/modos.
- [x] Compilar y enlazar el backend Unix de archivos en macOS 15/26 ARM
  mediante `vm-test`; ambos jobs pasaron en CI.
- [x] Confirmar esos mismos checks en el runner explícito `macos-15-intel`
  (run 38976311444).
- [x] Auditar con `rg` los guards Linux del runtime y separar los que
  protegían código portable de los que necesitan APIs exclusivas de Linux.
- [x] Añadir stat básico, cwd, rutas absolutas y canonicalización para que
  el compilador pueda resolver imports; incluir `System.env` y `System.pid`
  sin depender de que los procesos ya estén portados.
- [x] Validar en macOS ARM `single_binary` (19 casos) y `source_paths`
  (10 casos), incluidos imports y rutas temporales reales (run 38976311444).
- [x] Añadir regresión directa para pipe vacía, datos y EOF de FIFO;
  pasa en Linux y macOS ARM (run 38977386750).
- [x] Confirmar en CI macOS ARM las correcciones de borrado, rename, EOF de
  FIFO y lectura de `/dev/urandom`, con sus regresiones (run 38977386750).
- [x] Resolver UTF-8, rutas Windows con unidad, UNC, separadores y nombres
  con espacios; no confundir sintaxis de imports con rutas del host.
- [x] Rechazar NUL y argumentos inválidos antes de abrir o truncar un
  archivo. Mantener la validación en la función pública que escribe.
- [x] Conservar timeouts, propiedad por tarea y cierre con flush al salir;
  una operación lenta no bloqueará las otras tareas.
- [x] Hacer portables los descriptores para pollers sin `/proc/self/fd`,
  comprobando el comportamiento de flags y offsets antes de duplicarlos.
- [x] Probar round trips de texto y bytes, Unicode, archivos vacíos,
  lecturas por chunks, límites, argumentos inválidos y datos intactos.
- [x] Portar los casos pertinentes del harness de pruebas; usar tests C o
  bytecode preparado si el driver todavía impide ejecutar fuentes.

- [x] Separar primitivas de archivos en `file_io.c` y rutas nativas en
  `file_windows.c`, compartiendo validación y buffers de `files.c`.
- [x] Confirmar en Windows los nuevos tests C de builtins: texto y bytes,
  append/flush/close, Unicode, rutas con unidad/UNC y errores sin truncado.
  Pasaron en Windows y macOS ARM (run 38978961607); Linux local también.
- [x] Mantener los borrados Windows deshabilitados hasta cubrir raíces,
  puntos, enlaces, junctions y carreras de sustitución sin tocar destinos.
  Docker es la capa ligera de aislamiento y reproducción para pruebas locales
  destructivas. En CI, los casos corren directamente en los runners efímeros
  de GitHub Actions, siempre confinados a scratch propio y comprobados con
  testigos hermanos; no tocar rutas del usuario o del checkout.

Progreso: el backend Unix de archivos compila y `make vm-test` pasa en macOS
15/26 ARM y macOS 15 Intel (run 38976311444).
En macOS, los errores del sistema usan `strerror()` y la
localización con `strerror_l()` queda solo en Linux; el fallback de
`agc_system_error` ya no duplica la implementación del backend. La prueba de
cierre espera de forma acotada a que libuv procese la finalización del worker;
`make vm-test` pasó en Linux. Windows ya tiene archivos normales, rutas UTF-8
y tests C nativos. Entorno/pid pasaron en los tres runners nativos
(run 39007934640); faltan streams especiales, comprobaciones
de cierre/timeout y el handoff seguro del driver.

Las regresiones C de archivos, cierre diferido, procesos y canal privado
pasaron en Windows y ambos Mac en el run 39009333069. El cierre de recursos
nativos espera hasta un segundo si ya no quedan trabajos de la VM; un worker
atascado sigue haciendo que el cierre falle inmediatamente. El bootstrap
completo, fixed point y smoke del binario copiado pasaron en Windows y ambos
runners de macOS (run 39012162044), por lo que los pasos 4 y 5 quedan cerrados.
El caso de FIFO con lector que cierra también pasó en macOS Intel al reintentar
el escritor de FIFO con nombre desde el timer.

Cierre: el backend permite leer las fuentes del compilador y guardar su
bytecode con los contratos existentes. El siguiente paso lo prueba completo.

## 5. Driver y compilador completo en los cuatro sistemas

Commit propuesto: `vm: bootstrap the single binary on Windows and macOS`.

Ubicaciones: `vm/agentica.c:60`, `vm/agentica.c:72`,
`vm/agentica.c:100`, `vm/launch.c:70`, `vm/launch.c:249`,
`vm/launch.c:286`, `Makefile:16`, `Makefile:484`, `Makefile:541`,
`Makefile:549`, `tests/test_single_binary.py:65`.

- [x] Portar localización del ejecutable, lectura de bytecode, entropía y
  apertura de archivos; usar modo binario en Windows cuando corresponda.
- [x] Resolver la ruta del ejecutable desde `launch` mediante libuv en Linux
  y macOS; el driver macOS ya compila, enlaza e inicia la carga de stage0.
- [x] Corregir targets, dependencias y comandos que asumen `dist/agentica`
  sin `.exe`, utilidades GNU o rutas POSIX.
- [x] Construir desde stage0 y ejecutar stage1, stage2 y stage3 en cada
  plataforma; comprobar el punto fijo también con el binario final.
- [x] Confirmar bootstrap y fixed point completo en Linux, macOS 15/26 ARM
  y macOS 15 Intel (run 38976311444).
- [x] Probar help, version, check, compile, ejecución de fuentes y bytecode,
  imports relativos y de stdlib, errores y argumentos de programa.
- [x] Probar el binario copiado a otro directorio, sin depender de cwd,
  fuentes del repo, Racket ni un ejecutable Linux auxiliar.

Progreso: la búsqueda de la ruta propia pasó del driver a la interfaz de
`launch`; usa libuv para resolverla en cada sistema. Los targets principales
de Make y el helper Python ya buscan `dist/agentica.exe` en Windows. En Linux
pasaron el fixed point, los 19 casos del binario y los 25 casos de CLI.
El driver macOS ya compila y enlaza. Stage0 referencia también System.env,
System.pid y Process; se habilitaron sus implementaciones POSIX/libuv en macOS,
con streams y canal privado. El backend de archivos normales Windows, el
handoff seguro y los procesos que referencia stage0 ya cubren el bootstrap y
las pruebas CLI completas en Windows.

Cierre: un programa sencillo se compila y ejecuta nativamente en los cuatro
sistemas. Esto todavía no certifica archivos avanzados, procesos o red.

## 6. Archivos avanzados y operaciones seguras

Commit propuesto: `vm: port safe filesystem mutations and metadata`.

Ubicaciones: `vm/files.c:1283`, `vm/files.c:1294`,
`vm/files.c:1300`, `vm/files.c:1306`, `vm/files.c:1488`,
`vm/files.c:1589`, `vm/tree.c:173`, `vm/tree.c:202`,
`vm/tests/tree_test.c:1`, `tests/test_filesystem.py:55`.

- [x] Portar listar y crear directorios, creación privada, metadatos,
  lstat y locks de archivos normales. Los tests C y el smoke del bootstrap
  pasan en Windows y ambos Mac (run 39031970537, commit `de9be0cf`).
- [ ] Completar la conformidad multiplataforma de lectura por líneas,
  borrado y renombrado sin reemplazo. Windows ya habilita remove y rename;
  quedan los huecos de evidencia enumerados abajo.
- [ ] Mantener las garantías de no seguir enlaces durante borrado y no
  reemplazar destinos. Usar APIs nativas con esas garantías, no secuencias
  de comprobar y actuar que abran carreras.
- [x] Definir y comprobar ACL de creación privada en Windows; mode 0600
  por sí solo no demuestra acceso exclusivo del propietario. El backend
  comprueba propietario y DACL protegida sobre el objeto abierto; los tests C
  nativos pasan (runs 39012162044 y 39031970537).
- [x] Definir cómo se representan permisos e identificadores de propietario
  donde no existen los campos Unix, y documentar cualquier diferencia real.
- [ ] Cubrir enlaces, junctions y reparse points relevantes de Windows;
  tratar límites de profundidad y errores parciales sin ampliar el borrado.
- [ ] Probar destinos existentes, rutas peligrosas, NUL, fallos de permisos,
  carreras con enlaces, lock contendida y liberación al cerrar o cancelar.

Progreso: `File.try_lock` usa `LockFileEx` en Windows. La contención devuelve
`ok(false)` y los fallos de acceso siguen siendo errores. Repetir el lock sobre
el mismo handle devuelve `ok(true)`. Los tests C y el smoke del producto cubren
contención y liberación al cerrar; el test C Windows también comprueba que el
lock impide leer desde otro handle. Esta diferencia respecto al `flock`
advisory de Unix está documentada en gramática, sitio y skill. Pasaron los
jobs nativos Windows y ambos Mac del run 39031970537. El paso 6 sigue abierto
por la conformidad restante de rutas, enlaces/reparse points, lectura por
líneas y cancelación del propietario de locks; los backends ya existen.

Cierre: los casos de escritura y borrado inválidos preservan los datos
previos y las pruebas de enlaces no escapan del árbol temporal del test.

### Progreso del paso 6

PR #343 fusionado en `f4f51513`: aislamiento y operaciones Windows.
PR #348 fusionado en `80071958`: traducción de errores Windows.
PR #349 fusionado en `d673ad50`: metadatos y pruebas nativas de locks.
Todos tuvieron CI verde, incluidos los jobs nativos Windows y macOS.
Las casillas sin marcar conservan requisitos pendientes o cobertura parcial;
no significan que falte toda la implementación.

Orden: aislamiento → contrato de rutas → rename → metadatos/lectura/locks
→ backend de remove → conformidad y habilitación. Dividir en incrementos
revisables; cada uno debe conservar Linux y sus propios contratos.

#### 6a. Aislamiento obligatorio antes de probar borrados

- [x] Crear una ruta dedicada: `make tests KIND=files` y los aliases
  `windows-docker-remove-check`/`windows-docker-remove-wine-check` delegan al
  launcher confinado, no al contenedor general con checkout escribible.
- [x] Compilar por separado. Ejecutar las pruebas desde un contenedor con
  el checkout/binarios montados en solo lectura y los datos, HOME, TEMP y
  WINEPREFIX dentro de almacenamiento temporal desechable del contenedor.
  No montar carpetas del usuario, unidades del host ni el socket de Docker;
  tampoco usar mounts de escritura al checkout para guardar resultados.
- [x] Contenedor sin privilegios, sin red durante los tests y con límites
  de memoria, procesos y tiempo. En Linux, usar rootfs de solo lectura,
  capacidades eliminadas y no-new-privileges; adaptar esas protecciones al
  runtime Windows sin asumir que comparte los flags de Linux.
- [x] Cada caso tendrá un árbol víctima y un árbol testigo hermano, ambos
  creados por el test dentro del contenedor. Comprobar contenido e identidad
  de los testigos antes/después; nunca usar rutas reales del host como destino
  de un enlace, junction o argumento peligroso.
- [x] Separar los casos destructivos de `vm/tests/files_test.c`,
  `vm/tests/tree_test.c` y los unittest afectados para que una ejecución
  directa del target normal no active borrados de este trabajo. Esto incluye
  las pruebas de rechazo: un bug podría convertir un rechazo en un borrado.
  Auditar también los borrados del handoff privado que se invoquen al validar.
- [x] El launcher local debe exigir Docker para seleccionar los casos
  destructivos y fallar cerrado si Docker/imagen no están disponibles: nunca
  fallback local al host. En CI no se requiere Docker: los casos pueden correr
  en Actions solo si el runner es efímero y el test verifica en runtime su
  directorio scratch, su víctima y sus sentinels antes y después de cada
  mutación. Una variable `CI=1` no sustituye esas comprobaciones.
- [x] Primer gate: validar el montaje de solo lectura y que todos los paths
  del test pertenecen al almacenamiento temporal, sin invocar aún el backend
  de borrado que se quiere probar. Probe real superado en Docker; el backend
  se ejecutó después, en una invocación aislada separada.

En local, la ruta soportada para ejecutar pruebas destructivas es el launcher
Docker, con el checkout read-only y scratch efímero del contenedor. En Actions,
las pruebas destructivas corren directamente en la máquina efímera del runner;
Docker no es requisito. Los tests deben crear víctimas y sentinels dentro de
un directorio temporal exclusivo por caso, validar el confinamiento antes de
llamar al backend y comprobar después el contenido/identidad de los sentinels.
No se usan rutas del checkout, home del usuario ni destinos externos como
víctimas/enlaces. La prueba Windows nativa se ejecuta en `windows-2025` con su
filesystem efímero y paths confinados; no depende de Wine ni de un contenedor
Windows. Wine es solo una comprobación local complementaria. Si un test no
puede demostrar el confinamiento en el runner, falla cerrado. Mantener el
backend sin habilitar hasta que la semántica nativa de NTFS, ACL y reparse
points tenga evidencia adecuada.

Validación local posterior al primer gate: `tree-test` y
`files_private-test` pasaron dentro del contenedor, junto con 9 regresiones
Python aisladas y los 6 escenarios BDD. Los 10 tests mock del launcher también
pasaron. Se corrigió la recogida accidental de clases de tests importadas;
los peers temporales necesitan ejecución dentro del tmpfs privado. El intento
Docker/Wine superó la comprobación de frontera, pero venció su límite de 120 s
sin completar el test de rechazo Windows. No quedaron contenedores propios
activos. Estado actualizado tras #343: ya existe evidencia nativa Windows;
Wine sigue sin validar completamente su ruta aislada. El último intento del
launcher falla durante la creación del prefix con `No space left on device`
y `could not load kernel32.dll`; no atribuirlo a disco del host sin distinguir
el tmpfs limitado del contenedor. Queda auditar esa ruta, no bloquear por ella
la evidencia nativa ya obtenida.

#### 6b. Validar las rutas originales antes de normalizarlas

- [x] Mantener la comprobación de tipo, NUL y timeout en la API pública.
  Añadir un validador puro de la ruta original para remove: no llamar primero
  a `agc_host_path`/`agc_fs_absolute`, que en Windows borran la evidencia de
  `.` y `..`. Revisar `path_op` y `builtin_remove` para preservar ese orden.
- [ ] Definir y probar el rechazo de vacío, raíces de unidad y UNC,
  `C:`, puntos finales y `dir/..`, con ambos separadores y variantes de
  barras finales. No probar un borrado real de una raíz: validar esas cadenas
  con funciones puras. En local, correrlos mediante el launcher Docker; en
  Actions, con inputs puros y ninguna llamada destructiva.
- [ ] Definir antes de implementarlo el tratamiento de nombres de dispositivo,
  prefijos de namespace extendido, ADS, puntos/espacios finales y reparse tags
  desconocidos. Rechazar lo que no se pueda interpretar sin ambigüedad.
- [ ] Conservar las diferencias existentes: missing es éxito; `file/child`
  y un enlace con barra final no se convierten en éxito ni siguen el destino.

#### 6c. Rename sin reemplazo

- [x] Implementar la operación nativa en el adaptador Windows, manteniendo
  validación y Result/timeout en `files.c`. Elegir una primitiva del sistema
  que no reemplace el destino; sin comprobar-existencia-seguido-de-rename,
  sin copiar/borrar como fallback entre volúmenes y sin flags de reemplazo.
- [ ] Cubrir archivos, directorios y el movimiento del enlace mismo;
  destinos existentes de todos esos tipos deben conservarse byte a byte.
  Probar acceso denegado, rutas inválidas y cambio de volumen sin pérdida.
- [x] Carrera acotada de varios procesos hacia un nombre: un ganador, ningún
  overwrite y todos los perdedores conservan sus fuentes. Ejecutarla también
  dentro del árbol temporal propio en Actions; en local, ejecutar la regresión
  por el launcher Docker.

#### 6d. Cerrar las diferencias de metadatos, líneas y locks

- [x] Documentar los valores reales de mode/user_id/group_id de libuv en
  Windows; no presentar bits Unix sintéticos como una garantía de ACL.
  La creación privada sigue comprobando propietario y DACL del objeto abierto.
- [ ] Probar lectura por líneas en archivos normales: vacío, LF/CRLF,
  UTF-8 inválido, última línea sin terminador, límites y fin anticipado.
  Cubrir error/cancelación y cierre del handle sin depender de streams
  especiales, que pertenecen al paso 7.
- [ ] Completar locks entre procesos: liberación al terminar/cancelar la tarea
  propietaria y al morir el proceso; conservar contención frente a errores de
  acceso, read-handle locking e idempotencia. No repetir lo ya demostrado
  como si faltase implementar el builtin.

Progreso de locks (#349): pasan contención entre procesos, liberación al
terminar y matar el proceso, fin de tarea, cierre explícito e idempotencia.
El proceso sigue vivo durante la prueba de fin de tarea. Sigue pendiente
cancelación de la tarea propietaria y auditar la cobertura de lectura por
líneas; no marcar 6d entero como terminado.

#### 6e. Remove Windows: recorrido anclado en handles, sin seguir enlaces

- [x] Mantener deshabilitado hasta tener evidencia nativa; la habilitación
  ocurrió en #343. Las APIs nativas permanecen en el adaptador, sin duplicar
  scheduler, timeouts ni propiedad de recursos.
- [x] Abrir y examinar cada objeto sin seguir reparse points. Anclar el
  recorrido en handles de directorios ya abiertos: una comprobación de
  atributos seguida de una apertura por pathname no evita sustituciones.
  `FILE_FLAG_OPEN_REPARSE_POINT` solo no resuelve los componentes intermedios.
- [ ] Borrar el enlace/junction mismo sin entrar en su destino. Definir qué
  ocurre con mount points y tags desconocidos, y fallar de forma segura cuando
  una API no permita conservar el contrato frente a carreras.
- [x] Borrar el objeto validado mediante su handle; evitar reabrir o borrar
  por una ruta que un tercero pueda haber sustituido. No cerrar el handle
  antes de completar la operación que requiere su identidad.
- [ ] Verificar límite de profundidad 128, cierre de handles y progreso
  acotado. La implementación actual es recursiva con límite explícito, no
  iterativa; no reescribir sin demostrar un problema de stack/seguridad.
  #351 prueba nativamente fallo al alcanzar profundidad y cierre de handles.
  Queda completar evidencia de desaparición y errores parciales.
- [x] Mantener la semántica de timeout: el error no implica que se haya
  detenido una mutación ya iniciada en el pool. No liberar memoria ni handles
  mientras el worker pueda seguir usándolos.
- [ ] Probar enlaces de archivo/directorio, enlaces rotos, junctions, cambios
  concurrentes de nombre/tipo, sustitución por enlaces, profundidad,
  read-only/ACL denegada y desaparición entre enumeración y open. En Actions,
  cada víctima y sentinel vive bajo scratch temporal del caso, creado y
  confinado en runtime; en local, ejecutar los casos mediante Docker. Coordinar
  carreras con barreras/hooks deterministas; stress repetido será slow/CI, sin
  sleeps usados como prueba de que ocurrió la carrera.

#### 6f. Gate final y publicación del contrato

- [ ] Añadir una matriz de evidencia por operación y plataforma: Docker local
  para reproducción Linux, Wine opcional, y runners nativos de Actions para la
  semántica de cada SO.
- [x] El subset destructivo requiere el launcher Docker al ejecutarse
  localmente; en Actions puede correr directamente en el runner efímero tras
  probar confinamiento de scratch y sentinels. Los targets normales locales
  rechazan su selección directa; CI invoca los casos explícitamente después
  de preparar el scratch. Si una plataforma no puede probar confinamiento o
  limpieza, marcar su gate bloqueado, no saltarlo en verde.
- [ ] Cada arreglo lleva regresión; cada implementación nativa lleva revisión
  de seguridad. Actualizar gramática, sitio, programming/development skills
  y CHANGELOG solo con las garantías demostradas.
- [x] Habilitar `Path.rename` y `Path.remove` por separado, al pasar sus gates.
  No marcar todo el paso 6 como terminado por tener solo tests verdes de Wine.
- [ ] Mantener `plan.md` local y sin seguimiento. No ejecutar pruebas
  destructivas durante esta fase de planificación.

### Current execution evidence

PR #351 merged as `85d7223b` (head `de6aa95e`; native Windows, macOS and
Linux checks green): Wine storage, cross-volume rename via `MoveFileExW`
without copy, symlink remove/rename, and remove under denied DELETE.
Rename under denied DELETE is not claimed. Remaining phase 6 gates are
in the next PRs: other reparse tags, deterministic enumeration/open
interleavings, and 6f closure.

Previous increment notes:

PR #351 contains the isolation storage fix and additional conformance tests.
The first pushed head `e7654284` passed Platforms in run `39125128067`;
that subset is not a completion gate for all remaining requirements.
The initial increment passed native Windows Platforms: unsafe path aliases,
read-only failure, depth failure/handle cleanup, destination types, junction
rename, lock-owner cancellation and line decoding. The following head exposed
that backup intent bypassed the denied DELETE ACL; removing it fixed that
behavior natively. The latest Platforms run passed ACL-denied remove with an independent Win32
precondition and confined localhost SMB remove/rename with sentinels
(`39136358678`). The SMB fixture is committed and cleaned up by exact
share-name/path. Platforms rerun passed after a transient macOS `loop_test`
assertion. Local launcher tests: 19 passed. Expanded confined Wine group:
25 cases, 15 expected native-only skips. Skips are not native proof.

### Execution plan to finish phase 6

Base: `master` at `dd862167`; working branch: `plan/phase6-remaining`.
PRs #343, #348, #349 and #350 are merged. Do not reimplement their work.
Keep this file local. Mark a requirement complete only with matching evidence.

1. **Isolation (6a).** Audit launcher boundaries, scratch ownership, sentinels
   and cleanup. Diagnose Wine prefix storage inside the container: `/tmp` is
   currently capped at 1 GiB. Measure initialization without destructive
   programs, then adjust only bounded disposable storage if justified. Add a
   launcher regression and run the confined Wine group. Never fall back to
   host execution. Wine does not replace native Windows evidence.
   Progress: measured the existing prefix at 1.4 GiB, above the launcher's
   1 GiB `/tmp` limit. Changed only the Wine mode to a bounded 3 GiB tmpfs;
   rootfs/checkout remain read-only and network/capability restrictions stay.
   All 19 launcher tests pass. The confined Wine group now finishes in 121 s:
   14 cases, 8 expected native-only skips. This validates the storage fix,
   not the skipped native security cases. The rest of the isolation audit
   remains open.
2. **Original paths (6b).** Native cases now cover empty/NUL/bad timeout,
   drive and UNC roots, drive-relative roots, separators, dot components, ADS,
   device aliases and trailing dots/spaces. Audit the exact matrix; namespace
   prefixes and unusual device aliases still need a pure-validation matrix.
   Preserve missing-path success and errors for a child below a file or a final
   link with a trailing separator. Never attempt root deletion.
3. **No-replace rename (6c).** Existing tests cover moving a junction and
   preserving file/directory targets. Added a hosted-runner fixture that creates
   a fresh 64 MiB NTFS VHD under scratch, assigns a free letter, verifies it,
   and detaches/deletes the exact image. It asserts cross-volume failure and
   intact source. Native evidence is pending; do not infer success from the
   runner not yet executing it. SUBST alone is not evidence. Rename under
   denied DELETE ACL is not covered; do not infer it from remove.
4. **Lines and locks (6d).** Native cases now cover ordinary files: empty,
   LF/CRLF, invalid UTF-8, unterminated last line, line limit, early exit,
   callback/decode error, reader cleanup while its process is alive, and
   cancellation of the lock-owning task while the process survives. Retain
   process-death, task-end, contention and idempotence. Audit the acceptance
   matrix; do not repeat existing coverage.
5. **Handle-relative remove (6e).** Native evidence covers denied DELETE
   ACL (independent Win32 precondition), read-only failure, depth failure
   while the process stays alive, and localhost SMB remove/rename under
   scratch. Audit relevant reparse tags/mount points, the exact depth boundary,
   partial errors and disappearance/replacement between enumeration and open.
   Existing ancestor-swap stress preserves sentinels but does not force that
   interleaving. Add deterministic synchronization if needed; stress belongs
   in slow tier. Traversal remains recursive with an explicit depth bound; do
   not convert it to iterative without a demonstrated stack/safety need.
6. **Final gate (6f).** Record operation/platform/test/result evidence, audit
   skips and scratch cleanup, update grammar/site/skills/changelog for the
   proven contract, and run native Windows/macOS plus Linux Docker coverage.
   Close phase 6 only when each remaining requirement is proven or explicitly
   narrowed with its rationale. Do not claim complete coverage from Wine.

Deliver small PRs in this order, each with focused tests and an honest body.
No destructive tests on the host. No extra review rounds for minor findings
alone. Security or behavior changes require matching native evidence.

## 7. Entrada, salida y pipes sin bloquear el scheduler

Commit propuesto: `vm: port asynchronous standard streams`.

Ubicaciones: `vm/input.c:46`, `vm/input.c:103`,
`vm/output.c:353`, `vm/output.c:486`, `vm/stream.c:208`,
`tests/test_vm_stdout.py:1`, `tests/test_vm_stop.py:1`.

- [x] Mover stdin Windows a un trabajo del pool y compartir buffer, FIFO y
  entrega de EOF con Unix. Documentar la excepción de §14.1: una lectura
  pendiente ocupa un worker, no se interrumpe al cancelar y no se espera al
  salir del proceso.
- [ ] Completar stdout, stderr, pipes y terminales con el mecanismo
  apropiado para cada tipo de handle; Windows no permite uv_poll sobre
  cualquier descriptor como si fuera un socket Unix.
- [ ] Conservar backpressure, EOF, flush, timeout de salida y diagnósticos
  completos cuando varias tareas escriben al mismo tiempo.
- [ ] Probar lector silencioso, consumidor lento, pipe cerrado, cancelación
  y salida con buffers pendientes; las otras tareas deben poder avanzar.
- [x] Mantener texto y bytes sin conversiones CRLF accidentales en Windows:
  streams estándar en modo binario, también antes de `--version`; smoke de
  stdin con NUL, CR/LF, Ctrl+Z y 0xff (run 39031970537).
- [x] Comprobar que stdin con una pipe abierta y vacía no impide avanzar
  timers ni salir al terminar main; smoke nativo en Windows y ambos Mac
  (run 39031970537).
- [ ] Ejecutar el smoke manual de consola Windows de
  `.agents/skills/agentica-development/references/ci.md`: entrada interactiva,
  Ctrl+C y Ctrl+Break. Las pipes y Wine no verifican las señales de teclado.

Cierre: ni stdin silencioso ni stdout lleno inmovilizan toda la VM y la
salida termina dentro del límite configurado.

## 8. Procesos, captura y limpieza

Commit propuesto: `vm: port subprocess execution and lifecycle`.

Ubicaciones: `vm/process.c:618`, `vm/process.c:750`,
`vm/process.c:812`, `vm/process.c:817`, `vm/launch.c:107`,
`tests/test_process.py:14`, `tests/agentica_test.py:283`,
`tests/agentica_test.py:495`.

- [ ] Portar spawn normal y capturado, cwd, entorno, stdin, stdout, stderr,
  espera, output y close mediante libuv y las APIs nativas necesarias.
- [ ] Probar argumentos con espacios, comillas, Unicode y argumentos vacíos
  sin introducir un shell implícito ni inyección por quoting.
- [ ] Preservar `--allow-run`, búsqueda de comandos, variables privadas y
  aislamiento de los descriptores o handles heredados.
- [ ] Definir terminación y escalado en Windows, donde señales Unix y
  grupos de procesos no tienen una equivalencia directa; cubrir descendientes
  y cierre al morir el padre, usando Job Objects si se necesitan.
- [ ] Reemplazar pruebas que consultan `/proc` por observación portable del
  proceso, sin debilitar la comprobación de que no quedan hijos vivos.
- [ ] Probar spawn fallido, timeout, cancelación del propietario, salida
  abundante, lector lento, cierre repetido y ausencia de procesos huérfanos.

Cierre: los procesos no bloquean la VM ni sobreviven al cierre que debería
terminarlos; los argumentos llegan literalmente al peer independiente.

## 9. Canal privado entre procesos y test runner

Commit propuesto: `vm: port child channels and the BDD runner`.

Ubicaciones: `vm/process.c:664`, `vm/process.c:822`,
`vm/duplex.c:66`, `vm/duplex.c:74`, `vm/duplex.c:305`,
`tests/test_vm_child_channel.py:18`, `tests/test_bdd.py:1`,
`tests/test_single_binary.py:65`.

- [ ] Portar el canal bidireccional con pipes nativos o libuv y verificar
  cómo hereda el hijo el endpoint; no asumir que socketpair y fd 3 funcionan
  igual en Windows.
- [ ] Mantener el canal privado separado de stdin/stdout, no heredarlo a
  nietos y conservar el framing, límites y semántica de cierre.
- [ ] Probar mensajes en ambas direcciones, EOF, exceso de tamaño,
  cancelación y desaparición de padre o hijo.
- [ ] Ejecutar unit tests y BDD reales con `agentica test`, incluidos runner
  embebido, alternativa compilada y errores de infraestructura.

Cierre: `agentica test` funciona con el binario distribuible sin depender
de `/bin/sh`, fd Unix privados ni programas auxiliares del checkout.

## 10. TCP

Commit propuesto: `vm: enable TCP networking across platforms`.

Ubicaciones: `vm/tcp.c:8`, `vm/tcp.c:979`, `vm/tcp.c:985`,
`vm/stream.c:208`, `tests/test_vm_tcp.py:205`.

- [ ] Compartir conexiones, DNS, listeners, accept, lectura y escritura
  sobre libuv; aislar diferencias en tipos de socket y errores del host.
- [ ] Preservar timeouts, propiedad, backpressure y cierre de conexiones
  pendientes o aceptadas cuando termina su tarea.
- [ ] Probar contra peers Python/Node independientes: IPv4, IPv6 cuando
  esté disponible, puerto 0, rechazo, EOF, timeout y tráfico fragmentado.
- [ ] Comprobar conexiones simultáneas, cancelación durante connect o accept
  y liberación del puerto al terminar.

Cierre: TCP funciona en las cuatro arquitecturas sin fugas de sockets ni
dependencias de servicios externos.

## 11. TLS

Commit propuesto: `vm: enable verified TLS across platforms`.

Ubicaciones: `vm/tls_openssl.c:13`, `vm/tls_openssl.c:47`,
`vm/tcp.c:8`, `vm/tests/tls_test.c:181`, `tests/test_vm_tls.py:1`,
`docs/vm/10-io-tls.md:1`.

- [ ] Activar el adaptador OpenSSL en todos los sistemas y enlazar las
  bibliotecas vendidas, sin cambiar las garantías de verificación.
- [ ] Resolver las CA de confianza de macOS y Windows con una estrategia
  explícita: almacén nativo o bundle mantenido y distribuido. No desactivar
  verificación ni asumir que existen rutas Linux en esos sistemas.
- [ ] Conservar SNI, verificación de hostname/IP, CA explícita, protocolos
  mínimos y códigos propios de error.
- [ ] Probar handshake fragmentado, certificado válido, no confiable,
  expirado, hostname incorrecto, close_notify, EOF truncado y cancelación.

Cierre: TLS cliente y servidor funcionan con las mismas comprobaciones de
identidad; el binario empaquetado tiene una fuente de confianza funcional.

## 12. HTTP

Commit propuesto: `vm: enable HTTP clients and servers across platforms`.

Ubicaciones: `vm/http_server.c:10`, `vm/http_client.c:1`,
`vm/http_pico.c:1`, `stdlib/http.agc:1`, `tests/test_vm_http.py:1`.

- [ ] Habilitar cliente y servidor sobre los backends TCP/TLS portados,
  manteniendo parsing, límites y lógica de protocolo compartidos.
- [ ] Probar HTTP y HTTPS, keep-alive, cuerpos fragmentados, chunked,
  respuestas parciales, cliente desconectado y apagado del servidor.
- [ ] Comprobar contra implementaciones independientes; Node para los casos
  de protocolo que el servidor estándar de Python no soporta.
- [ ] Verificar que timeouts y cancelación cierran conexiones y no entregan
  una conexión incompleta al pool.

Cierre: los ejemplos y tests de HTTP/HTTPS cliente y servidor pasan en los
cuatro runners sin desactivar casos de red por sistema operativo.

## 13. Matriz de conformidad del producto

Commit propuesto: `ci: verify the full product on all release platforms`.

Ubicaciones: `.github/workflows/platforms.yml:1`,
`.github/workflows/ci.yml:1`, `Makefile:125`,
`tests/agentica_test.py:110`, `tests/agentica_test.py:283`,
`tests/test_stdlib_distribution.py:1`, `tests/test_single_binary.py:65`.

- [ ] Convertir las comprobaciones incrementales en una matriz estable de
  cuatro sistemas, con checks identificables por plataforma y arquitectura.
- [ ] Ejecutar build desde stage0, fixed-point, tests C, CLI, lenguaje,
  archivos, procesos, tareas y red en cada plataforma.
- [ ] Auditar skips y herramientas requeridas: un built-in prometido no
  puede quedar sin probar por una condición heredada de Linux-only.
- [ ] Distinguir únicamente las pruebas de capacidades exclusivas del host,
  con motivo concreto; mantener portable el comportamiento observable común.
- [ ] Mantener sanitizadores, fuzzing, GC stress y límites del loader, con
  cobertura adicional en otras plataformas donde la toolchain lo permita.
- [ ] Revisar documentación, ejemplos, skills y la entrada breve de
  `CHANGELOG.md:8` para reflejar el soporte realmente verificado.

Cierre: el conjunto acordado de funcionalidades tiene evidencia positiva
en cada sistema. Los jobs verdes que solo compilan stubs no cuentan.

## 14. Empaquetado y release de los cuatro binarios

Commit propuesto: `release: publish native binaries for four platforms`.

Ubicaciones: `.github/workflows/release.yml:13`,
`.github/workflows/release.yml:106`,
`.github/workflows/release.yml:139`,
`.github/workflows/release.yml:145`, `Makefile:125`,
`docs/vm/10-dependencies-and-platforms.md:1`,
`docs/vm/11-build-ci-supply-chain.md:1`, `README.md:9`,
`.agents/skills/agentica-development/references/ci.md:325`.

- [ ] Añadir matriz nativa y paquetes con nombres de sistema/arquitectura
  estables. El publish necesitará el éxito de todos los builds.
- [ ] Conservar Zig, glibc 2.28, checks ELF y hardening de Linux; aplicar
  comprobaciones Mach-O y PE equivalentes donde correspondan.
- [ ] Fijar deployment target de macOS y comprobar arquitectura y librerías
  importadas con las herramientas de cada sistema.
- [ ] Enlazar estáticamente dependencias de terceros cuando sea posible;
  incluir cualquier dependencia inevitable y sus licencias. En Windows,
  comprobar que el paquete no depende de `msys-2.0.dll` ni del PATH de UCRT64.
- [ ] Mantener licencias, NOTICE y checksums de los cuatro archivos; validar
  que no falte ni se duplique ninguna combinación esperada.
- [ ] Extraer cada paquete en una ruta con espacios y Unicode y probarlo
  fuera del checkout y del entorno de build, con PATH controlado.
- [ ] Desde ese paquete probar version, help, check, compile, run, imports
  de stdlib, unit tests/BDD, archivos, procesos y networking localhost.
- [ ] La ejecución manual solo subirá artefactos; la publicación seguirá
  condicionada a un tag cuyo valor coincida con VERSION.
- [ ] Documentar requisitos mínimos e instrucciones de instalación para
  cada sistema. No presentar firma o notarización como existentes si no se
  han configurado; registrarlas como seguimiento si requieren credenciales.

Cierre: una ejecución manual completa produce los cuatro paquetes, y cada
uno funciona en su runner nativo después de extraerlo.

## Bucle de validación con CI y releases manuales

- [x] Mantener los checks rápidos en `platforms.yml` desde el primer paso,
  ampliando la cobertura conforme queden disponibles los backends. Windows
  ejecuta bootstrap, fixed-point, tests C, `test_single_binary.py`,
  `test_source_paths.py` y `test_platform_bootstrap.py`.
- [x] Comprobar que CI está ejecutando el SHA del commit recién subido:
  `de9be0cf09ab7812f0cc12f85a684f514e938fec` en PR #342. Jobs nativos verdes
  en run 39031970537; `test` y `vm-sanitizers` verdes en run 39031970534,
  y `site-examples` verde en run 39031970542. Sin checks pendientes ni fallidos;
  `dup-check` y `warm-third-party` omitidos según su condición de push.
- [ ] Revisar todos los fallos pertinentes y corregirlos antes de avanzar.
- [ ] Ejecutar un release manual cuando cambien el embedding, las
  dependencias, el driver o el empaquetado; al principio solo será exigible
  el alcance disponible, identificado explícitamente como parcial.
- [ ] Repetir la ejecución completa tras el paso 14 y comprobar artefactos,
  arquitecturas, dependencias y resultados de los paquetes extraídos.

Comandos de referencia, una vez subida la rama:

```sh
gh workflow run release.yml --ref feat/multiplatform-releases
gh run list --branch feat/multiplatform-releases
gh run view RUN_ID
gh run view RUN_ID --log-failed
gh run download RUN_ID --dir /tmp/agentica-release-check
```

## Criterio final

- [ ] Linux conserva su compatibilidad y no presenta regresiones.
- [ ] Windows, macOS Intel y macOS ARM ejecutan el compilador y las APIs
  públicas de archivos, procesos, tareas, TCP, TLS y HTTP.
- [ ] El usuario puede usar los paquetes sin un checkout del repositorio ni
  una instalación de MSYS2, Homebrew, Racket o herramientas de desarrollo.
- [ ] El release manual de la rama pasa y contiene exactamente los cuatro
  paquetes esperados y sus checksums.
- [ ] La documentación coincide con los binarios probados y todos los pasos
  completados tienen sus casillas marcadas con evidencia de CI.
