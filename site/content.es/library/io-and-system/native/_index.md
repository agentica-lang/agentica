---
title: Código nativo
weight: 7
description: Llama a funciones de C de una biblioteca nativa con un bloque extern.
source_hash: "47ca38fb1f58"
---

Un bloque `extern` nombra una biblioteca nativa y declara las funciones de C que tu programa llama desde ella. Cada línea es una firma con tipos de C y sin cuerpo; después, la función se llama como cualquier otra.

```agentica {mode="check"}
extern "libm.so.6"
  ## The cosine of x, in radians.
  def cos(x: C.Double) -> C.Double

  def labs(n: C.Long) -> C.Long
end

def main() -> Void
  puts(cos(0.0))
  puts(labs(-5))
end
```

- Las llamadas nativas funcionan en Linux y macOS (x86_64 y arm64) y en Windows x64, y `Native.wait_*` en Linux, macOS y Windows (en Windows, solo sockets). En otros sistemas, un programa que declara una función extern o llama a un integrado `Native.*` se rechaza antes de ejecutarse (`RUNTIME-NATIVE-UNSUPPORTED`, código de salida 2); `check` y `compile` funcionan en todas partes.
- El código nativo se ejecuta con los permisos de tu programa, y una firma incorrecta es comportamiento indefinido en C: declara cada función exactamente como la declara su cabecera de C. Una función variádica (`printf`) se declara con `...` ([funciones variádicas](/library/io-and-system/native/types/#variadic-functions-and-c-names)).
- Pon la documentación con `##` en las líneas `def` dentro del bloque.

Un paquete puede incluir su biblioteca o nombrar una del sistema en su `agentica.toml` (`[native.NAME]`, una entrada para cada uno de `linux`, `macos` y `windows`), y `extern "NAME"` en los archivos del paquete abre la correcta por su ruta en `deps/`. Los archivos de su carpeta `native/` se calculan con hash junto con el paquete, así que el archivo de lock los cubre. Una biblioteca de `native/` que carga otra hermana la encuentra en Windows (la carpeta de la DLL), pero en Linux debe compilarse con `RPATH=$ORIGIN` y en macOS con `@loader_path`. Mira [Paquetes](/tour/modules/).

El resto de la sección tiene sus propias páginas:

- Usa [Tipos y recursos](/library/io-and-system/native/types/) para los tipos de C, la lectura de memoria que devuelve C, búferes propios y memoria tipada, recursos, parámetros out, punteros a función de C, callbacks y estructuras de C.
- Usa [SQLite](/library/io-and-system/native/sqlite/) para un ejemplo completo: una biblioteca detrás de funciones seguras que devuelven `Result`.
- Usa [Llamadas compute](/library/io-and-system/native/compute/) para una llamada que puede tardar: las demás tareas siguen ejecutándose.
- Usa [Esperar un descriptor](/library/io-and-system/native/waiting/) para esperar un socket o un descriptor sin detener las demás tareas.
- Usa [Envolver una biblioteca de C](/library/io-and-system/native/wrapping/) para ocultar los hábitos de C de una biblioteca tras una API normal y entregarla en un paquete.
- Usa [Módulos nativos](/library/io-and-system/native/modules/) para código de C escrito para Agentica: recibe y devuelve valores de Agentica, y un resultado completo en una sola llamada.

## Cuál usar {#which-one}

`extern "LIB"` y `extern module` cumplen tareas distintas:

- `extern "LIB"` vincula una biblioteca de C existente tal como es: no escribes C, la biblioteca solo tiene que estar instalada, y encaja en unas pocas llamadas con argumentos escalares o punteros.
- `extern module` es C escrito para Agentica: compilas un archivo pequeño de C contra `agentica_native.h`, y una llamada recibe y devuelve valores de Agentica (listas, mapas, estructuras, recursos). Encaja en caminos críticos y en resultados completos: en `make bench-native` (`benchmarks/native/run.py`, Linux x86-64), una lista de 1000 estructuras tardó unos 65 µs con una sola llamada a un módulo y unos 562 µs con 1000 llamadas extern, cada una con un push.
- Usar las dos juntas es común: un módulo que envuelve una biblioteca de C, como SQLite, y le da al programa valores de Agentica.

## El bloque {#the-block}

- La biblioteca es una cadena simple: un nombre sin `/` (`"libm.so.6"`), que el sistema busca, o una ruta absoluta (`"/opt/tool/libtool.so"`). Cualquier otra cosa es `PARSE-EXTERN-LIBRARY`. Nunca se busca en la carpeta de trabajo. En Windows, un nombre (`"ucrtbase.dll"`) se busca junto a `agentica.exe` y en la carpeta del sistema, no en `PATH`; escribe una ruta absoluta con las barras invertidas escapadas (`"C:\\libs\\x.dll"`). Las DLL que necesita se buscan en su carpeta y en las carpetas predeterminadas, nunca en `PATH` (una DLL de MinGW que necesita `libgcc_s_seh-1.dll` debe tenerla junto a ella). Una ruta relativa ahí (`"lib\\x.dll"`, `"C:x.dll"`) es `RUNTIME-NATIVE-LOAD`. En macOS, un nombre (`"libsqlite3.dylib"`) se busca como `/usr/lib/NAME` (y en `DYLD_LIBRARY_PATH`), lo que encuentra las bibliotecas del sistema en la caché compartida de dyld (libc y libm son `"libSystem.B.dylib"`). Cualquier otra biblioteca usa su ruta absoluta (`"/opt/homebrew/lib/libpq.dylib"`; un paquete puede listar [candidatas](/tour/modules/) en su manifiesto). macOS quita las variables `DYLD_*` cuando un programa protegido, como `/usr/bin/env` o `/bin/sh`, inicia agentica, así que `DYLD_LIBRARY_PATH` no pasa por una línea shebang ni por un script de shell.
- La biblioteca se abre en la primera llamada a una de sus funciones y se queda abierta. Una biblioteca, dependencia o función que no se encuentra hace fallar esa llamada con `RUNTIME-NATIVE-LOAD`.
- `Native.load("NAME") -> Result[Void]` abre la biblioteca antes de su primera llamada: `ok`, y se queda abierta para las funciones del bloque, o `error` con el texto del cargador (`native: cannot open NAME: ...`). Un paquete puede entonces informar de una biblioteca que falta, o usar una alternativa, antes de cualquier efecto: `try Native.load("pq")`. El argumento es un literal de cadena con el mismo significado que en `extern "NAME"`, incluido el `[native.NAME]` del paquete; cualquier otra cosa es `CHECK-NATIVE-LOAD`. Una función que falta en la biblioteca hace que su primera llamada siga fallando con `RUNTIME-NATIVE-LOAD`.
- `Native.function?("NAME", "symbol") -> Bool` pregunta si la biblioteca se abre y exporta la función, así que un programa puede elegir una alternativa antes de llamar a una función declarada que una biblioteca opcional quizá no tenga (un `crypt_r` de bcrypt en una `libcrypt` que aporta el usuario): `if Native.function?("libcrypt.so.1", "crypt_r")`. `NAME` es un literal de cadena, como en `Native.load`; el símbolo es cualquier `String`. Es `true` cuando un `extern def` con este nombre de C se vincularía: en Linux y macOS la búsqueda (`dlsym`) también mira las dependencias de la biblioteca y sus símbolos de datos; en Windows, solo cuentan las exportaciones de la propia DLL. Una biblioteca que no se abre, una función que falta o un símbolo de más de 4096 bytes dan `false`; la biblioteca no se queda abierta (`Native.load` sí la deja abierta, y la primera llamada de una función del bloque la abre de todos modos). `--deny-native` la rechaza igual que a `Native.load`.
- Un nombre de `def` no lleva `?` ni `!`, ni aunque tenga un nombre de C después de `=` (`PARSE-EXTERN-NAME`); los parámetros no tienen valor predeterminado (`PARSE-EXTERN-DEFAULT`); solo cruzan los [tipos](/library/io-and-system/native/types/) y los recursos y estructuras del bloque (`PARSE-EXTERN-TYPE`).
- El bloque es público, así que sus funciones, recursos y estructuras se pueden importar desde otros archivos, salvo que vaya después de `private`. Las funciones ocupan el lugar de los `def` en el orden de declaración, y los recursos y estructuras el lugar de los tipos. Un bloque que declara un recurso o una estructura ocupa el lugar de los tipos como un todo, con sus funciones incluidas. En un bloque `extern module`, un recurso ocupa el lugar de un `def`, igual que las funciones del bloque.
- `extern` es una palabra clave solo al principio de una declaración de nivel superior, y `resource` solo al principio de una línea del bloque; en otros lugares son nombres comunes.

## Ejecución {#running}

- Una llamada `def` mantiene el planificador que la ejecuta hasta que devuelve, así que mantén cortas esas llamadas, y usa [`compute def`](/library/io-and-system/native/compute/) para las largas. `--max-steps` no puede detener una llamada a mitad.
- Las tareas en planificadores distintos (`--schedulers`) hacen sus llamadas nativas al mismo tiempo, tanto `def` como `compute def`, así que dos llamadas pueden estar dentro de una misma biblioteca a la vez. Una biblioteca que no es segura para hilos necesita un bloqueo alrededor de sus llamadas: `Native.mutex()` crea un `Native.Mutex`, y `lock.synchronize do ... end` ejecuta el bloque con él retenido y da el valor del bloque. Una tarea que espera el bloqueo se aparca, y las demás tareas siguen; quienes esperan lo reciben en el orden en que llegaron. El final de la tarea, un fallo o una cancelación incluidos, lo devuelve, pero una llamada `compute def` que el bloque inició lo mantiene tomado hasta que C devuelve. Una tarea que ya lo tiene y vuelve a llamar a `synchronize` falla con `RUNTIME-NATIVE-MUTEX`. Un `Native.Mutex` no es un dato: no tiene `==`, ni `to_s`, y no es una constante, así que un paquete lo crea en su función de apertura y lo guarda junto a su handle.

```agentica {mode="check"}
extern "libm.so.6"
  def cos(x: C.Double) -> C.Double
end

def main() -> Void
  lock = Native.mutex()
  value = lock.synchronize do cos(0.0) end
  puts(value)
end
```

- El código nativo tiene que reintentar las llamadas interrumpidas por `EINTR`: las señales del recolector pueden interrumpir las pausas y los sondeos.
- Un error `RUNTIME-NATIVE-*` o `RUNTIME-INTEGER-OVERFLOW` de una llamada extern tiene su tramo principal en la línea `extern def`; el lugar de la llamada está en la traza de pila.
- El código nativo está permitido por defecto y puede iniciar programas por sí mismo. `agentica --deny-native file.agc` (o cualquier flag `--deny-*`) rechaza un programa que declara cualquier función extern o llama a un integrado `Native.*` antes de que se ejecute nada (`RUNTIME-NATIVE-DENIED`, código de salida 2). Con `agentica test`, un archivo de prueba así es un error de archivo con ese código. Con estos flags, un [módulo nativo](/library/io-and-system/native/modules/) con una tabla `build` no se compila, y `agentica compile` lo rechaza (`PKG-NATIVE-BUILD`).
