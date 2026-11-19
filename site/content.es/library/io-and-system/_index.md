---
title: IO y sistema
weight: 5
description: Entrada y salida estándar, archivos, otros programas, la red y el sistema.
source_hash: "c48af99e69ad"
---

- [IO](/library/io-and-system/io/): imprime en la salida estándar y en el error estándar, y lee la entrada estándar.
- [File, Dir y Path](/library/io-and-system/files/): lee y escribe archivos, lista y crea directorios, y crea rutas.
- [Process](/library/io-and-system/process/): inicia otros programas, se comunica con ellos y espera a que terminen.
- [TCP, TLS y HTTP](/library/io-and-system/network/): consultas DNS, sockets, un cliente HTTP y un servidor HTTP.
- [Archivo comprimido](/library/io-and-system/archive/): extrae a un directorio privado nuevo los archivos que indiques de un TAR o un ZIP.
- [Logger](/library/io-and-system/logger/): niveles, manejadores con nombre y líneas de texto o JSON en el error estándar.
- [System, Time y Random](/library/io-and-system/system/): argumentos del programa, códigos de salida, relojes y números aleatorios.
- [Fechas y horas](/library/io-and-system/time/): fechas del calendario, horas del día y fechas y horas con un desfase UTC fijo.
- [Option parser](/library/io-and-system/option-parser/): lee la línea de comandos en valores con tipo, con predeterminados, valores permitidos, errores y un texto de ayuda.
- [Código nativo](/library/io-and-system/native/): llama a funciones C de una biblioteca nativa con un bloque `extern`.

Los archivos, los procesos y la red devuelven un `Result` y reciben tiempos de espera en milisegundos.
