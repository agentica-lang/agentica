---
title: The Aurora VM
weight: 5
description: How Agentica runs your program, the bytecode VM called Aurora, and the libraries it is built on.
---

Every Agentica program runs on a bytecode virtual machine written in C11. Its codename is Aurora. The codename appears only in the docs: the VM is part of the `agentica` binary, and bytecode files end in `.agcb`.

For the reasons behind these choices, see [Design decisions](/design/).

## From source to bytecode

The `agentica` command is one binary with two parts. The front end, written in Agentica and compiled to bytecode itself, reads your program: the lexer, the parser, the module linker, the checker and the lowering step. It passes the checked program, as bytecode in memory, to the VM, which runs it in a new runtime of the same process. The VM runs every program; there is no other backend.

You can also run the two steps yourself:

```sh
agentica compile file.agc -o file.agcb   # write bytecode
agentica run -- file.agcb                # run it on the VM
```

`run` must be the first word after `agentica`. The flags are in [Getting started](/getting-started/) and the [language specification](/reference/). Bytecode runs only on the VM of the same Agentica version.

## Inside the VM

- **Values.** Every value is 16 bytes: a tag, and a number, a boolean or a pointer. Immutable values (strings, lists, maps, structs, enums and results) are shared safely; mutable state lives only in handles (tasks, channels, files, sockets, listeners, processes and HTTP clients), and the Boehm garbage collector frees memory that is no longer used.
- **Loader.** A `.agcb` file is untrusted input. The loader checks all of it before anything runs (version, strings, indexes, registers, jump targets, and a step check in every loop and in every function that makes calls), so `--max-steps` holds even for a hostile file. A file over 256 MiB is refused as `agentica run: cannot read <file>`, and any other bad file as `agentica run: invalid bytecode: <reason>`; both exit with code 2.
- **Interpreter.** One loop reads and runs instructions. Calls push frames on the task's own stack, never on the C stack, and a tail call (`return f(...)` to a user function) reuses the current frame.
- **Tasks.** `Task.spawn` makes a green thread with its own registers and frames. One scheduler thread runs them from a queue, each for a turn of 2000 steps, so a busy loop cannot starve the others.
- **I/O.** A blocking call, such as reading a file or a socket or `Task.sleep`, parks only its own task while libuv does the work. File work runs on the libuv thread pool.
- **Waits.** A `Channel.send` or `Channel.recv` that must wait parks its task until a value or a free slot is ready. A timed `Task.await` waits on the task and on a timer at once, and whichever wakes the caller first decides the result.
- **Limits.** `--max-steps N` stops a program with `RUNTIME-STEP-LIMIT` after N steps, counted across all tasks; there is no limit by default. Calls nest at most 10,000 deep in each task. One more call fails with `RUNTIME-STACK-OVERFLOW`, and the error shows the call stack, with a repeated function on one line and its count. A tail call to a user function does not add depth.
- **Maps and lists.** A `Map` is a persistent hash array mapped trie (HAMT) that keeps insertion order; `Map.put` copies only the path to its key. A `List` is a persistent vector of 32 children per node with a small tail. Indexing takes at most four steps for a million items, and n pushes cost O(n) in total. A list of only Ints or only Floats keeps 8 bytes per item, and no tag. `List.take`, `List.drop` and `List.reverse` are O(n), and `List.sort` is O(n log n).
- **JSON.** `JSON.parse` reads text with yyjson, and the VM's own encoder writes it. A parsed object keeps each key once and encodes its keys sorted, so `JSON.encode(JSON.parse(text))` is canonical: two documents that differ only in spacing or key order encode the same.
- **Standard modules.** The `std/` modules (`std/queue`, `std/http`, `std/binary`, `std/toml`, `std/bdd`) are written in Agentica. They are embedded in the `agentica` command and linked into your program's bytecode like your own modules.

## What it is built on

The libraries below are pinned git submodules in `vm/third_party/`. The release builds them all into the `agentica` binary, which needs no system libraries beyond the C library. A default Linux `make` links the system OpenSSL 3 and libgc (found with `pkg-config`; Debian packages `libssl-dev` and `libgc-dev`). `make AGENTICA_GC=vendored AGENTICA_OPENSSL=vendored` builds the submodules instead (OpenSSL needs Perl 5). The release archives ship the license notices in `licenses/`.

| Library | Purpose | License |
|---|---|---|
| Boehm GC (bdwgc) | Garbage collector for program values | Boehm-GC license (permissive) |
| yyjson | Reads JSON text for `JSON.parse` | MIT |
| libuv | Event loop, file and socket I/O, timers, processes and the thread pool | MIT, with BSD-2-Clause and ISC parts |
| OpenSSL 3.5 | TLS for `TLS.connect`, `TLS.listen` and HTTPS | Apache-2.0 |
| picohttpparser | Parses HTTP start lines and headers | MIT (dual MIT or Perl license) |

The Unicode tables for case mapping and for printing text are not a submodule. They are generated from the Unicode Character Database into the VM source, under the Unicode License v3.

## Platforms

The release builds four native archives: Linux x86-64 (glibc 2.28 or newer), macOS Intel and Apple silicon (macOS 12 or newer) and Windows x86-64 (Windows 10 or newer). `TCP` and `TLS` run and are tested on all three systems; `std/http` is built on Linux and macOS only for now.

## Learn more

The design of the VM, with the reasons behind each choice, is in the [VM design documents](../../docs/vm/README.md) in the Agentica repository.
