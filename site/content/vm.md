---
title: The Aurora VM
weight: 5
description: How Agentica runs your program, the bytecode VM called Aurora, and the libraries it is built on.
---

Every Agentica program runs on a bytecode virtual machine written in C11. Its codename is Aurora. The codename appears only in the docs: the binary is `agentica-vm`, and bytecode files end in `.agcb`.

## From source to bytecode

The `agentica` command has two parts. The front end, written in Racket, reads your program: the lexer, the parser, the module linker, the checker and the lowering step. It turns the checked program into bytecode, writes it to a private temporary `.agcb` file and starts `agentica-vm` on it. The VM runs every program; there is no other backend.

You can also do the two steps yourself. `agentica compile file.agc -o file.agcb` writes the bytecode, and `agentica-vm -- file.agcb` runs it. The VM takes `--max-steps`, `--seed`, `--flush-timeout` (the variable `AGENTICA_FLUSH_TIMEOUT_MS` sets the same value), `--allow-run`, and `--ai` or `--json` before the `--`, and passes the words after the file to the program. A bytecode file runs only on the VM of the same Agentica version.

## Inside the VM

- **Values.** Every value is 16 bytes: a tag, and either a number, a boolean or a pointer. Strings, lists, maps, structs, enums and results are immutable, so many values can share them safely. The only state lives in handles: tasks, channels, open files, sockets, listeners, processes and HTTP clients. The Boehm garbage collector frees memory that is no longer used.
- **Loader.** A `.agcb` file is treated as untrusted input. The loader checks the whole file before anything runs: the version, every string, every index, register and jump target, and that every loop and every function that makes calls passes a step check, so `--max-steps` holds even for a hostile file. A file larger than 256 MiB is refused before loading, with `agentica-vm: cannot read <file>` and exit code 2. Any other file that fails stops with `agentica-vm: invalid bytecode: <reason>` and exit code 2.
- **Interpreter.** One loop reads and runs instructions. Agentica calls push frames on the task's own stack, never on the C stack, and a tail call (`return f(...)` to a user function) reuses the current frame.
- **Tasks.** `Task.spawn` makes a green thread: a task with its own registers and frames. One scheduler thread runs them from a queue. Each task runs for a turn of 2000 steps, then the next task gets its turn, so a busy loop cannot starve the others. A blocking call, such as reading a file, a socket or `Task.sleep`, hands its work to the libuv event loop and parks only its own task. File work runs on the libuv thread pool. A `Channel.send` or `Channel.recv` that must wait parks its task on a timer, and the scheduler wakes it when a value or a free slot is ready.
- **Limits.** `--max-steps N` stops a program with `RUNTIME-STEP-LIMIT` after N steps, counted across all tasks; there is no limit by default. Calls nest at most 10,000 deep in each task; one more fails with `RUNTIME-STACK-OVERFLOW`. A tail call to a user function does not add depth.
- **Maps and lists.** A `Map` is a persistent hash array mapped trie (HAMT) that also keeps the order in which keys were added. `Map.put` copies only the path to its key and shares the rest with the old map. A `List` is an immutable array: indexing is fast, and a change such as `List.append` makes a new copy.
- **JSON.** `JSON.parse` reads text with yyjson, and the VM's own encoder writes it. A parsed object keeps each key once and encodes with its keys sorted, so `JSON.encode(JSON.parse(text))` gives canonical text: two documents that differ only in spacing or key order encode the same.
- **Network and processes.** TCP and TLS sockets, child processes (only with `--allow-run`) and the HTTP client and server run on the event loop. TLS uses OpenSSL with certificate and hostname checks. A small C layer parses and checks HTTP messages, and the rest of HTTP is the `std/http` module.
- **Standard modules.** The `std/` modules (`std/queue`, `std/http`, `std/bdd`) are written in Agentica. They are embedded in the `agentica` command and linked into your program's bytecode like your own modules.

## What it is built on

The libraries below are vendored as pinned git submodules in `vm/third_party/`. The release builds all of them into the `agentica-vm` binary, so it needs no system libraries beyond the C library. A default `make vm` on Linux builds the same way except for OpenSSL and the Boehm GC: it links the system OpenSSL 3 and libgc (found with `pkg-config`, Debian packages `libssl-dev` and `libgc-dev`) dynamically. `make vm AGENTICA_GC=vendored` builds the Boehm GC submodule too. `make vm AGENTICA_OPENSSL=vendored` builds the OpenSSL submodule too, like the release, and needs Perl 5. Each library keeps its own license, and the release archives ship their notices in `licenses/`.

| Library | Purpose | License |
|---|---|---|
| Boehm GC (bdwgc) | Garbage collector for program values | Boehm-GC license (permissive) |
| yyjson | Reads JSON text for `JSON.parse` | MIT |
| libuv | Event loop, file and socket I/O, timers, processes and the thread pool | MIT, with BSD-2-Clause and ISC parts |
| OpenSSL 3.5 | TLS for `TLS.connect`, `TLS.listen` and HTTPS | Apache-2.0 |
| picohttpparser | Parses HTTP start lines and headers | MIT (dual MIT or Perl license) |

The Unicode tables for case mapping and for printing text are not a submodule: they are generated from the Unicode Character Database into the VM source, under the Unicode License v3.

## Platforms

Agentica runs on Linux. The release archive is for Linux x86-64 with glibc 2.28 or newer, Required CI runs on Linux only; a manual workflow builds and tests the VM on macOS and Windows. Those builds leave out libuv and OpenSSL, so files, processes, the network, the HTTP client and `Task.sleep` with more than 0 ms are missing there (they fail with `RUNTIME-INTERNAL`), and the `agentica` command is tested on Linux only.

## Learn more

The design of the VM, with the reasons behind each choice, is in the [VM design documents](../../docs/vm/README.md) in the Agentica repository.
