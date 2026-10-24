---
title: IO and system
weight: 5
description: Standard input and output, files, other programs, the network, and the system.
---

- [IO](/library/io-and-system/io/): print to standard output and error, and read standard input.
- [File, Dir and Path](/library/io-and-system/files/): read and write files, list and create directories, and build paths.
- [Process](/library/io-and-system/process/): start other programs, talk to them and wait for them.
- [TCP, TLS and HTTP](/library/io-and-system/network/): sockets, an HTTP client and an HTTP server.
- [Archive](/library/io-and-system/archive/): extract named files from TAR archives into a new private directory.
- [Logger](/library/io-and-system/logger/): levels, named handlers, and text or JSON lines on stderr.
- [System, Time and Random](/library/io-and-system/system/): program arguments, exit codes, clocks and random numbers.
- [Native code](/library/io-and-system/native/): call C functions of a native library with an `extern` block.

Files, processes and the network return a `Result` and take timeouts in milliseconds.
