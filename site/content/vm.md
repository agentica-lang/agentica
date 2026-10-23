---
title: The Aurora VM
weight: 6
description: How Agentica runs your program, the bytecode VM called Aurora, and the libraries it is built on.
---

Every program runs on Aurora, a bytecode VM written in C11 (the name appears only in the docs). The VM is part of the `agentica` binary; bytecode files end in `.agcb`. The reasons behind these choices are in [Design decisions](/design/).

## From source to bytecode

The `agentica` binary has two parts. The front end (lexer, parser, module linker, checker, lowering), written in Agentica and compiled to bytecode itself, passes the checked program as bytecode in memory to the VM, which runs it in a new runtime of the same process. You can run the steps yourself (flags: [Getting started](/getting-started/)):

```sh
agentica compile file.agc -o file.agcb   # write bytecode
agentica run -- file.agcb                # run it; `run` must be the first word
```

Bytecode runs only on the VM of the same Agentica version.

## Inside the VM

- **Values.** Every value is 16 bytes: a tag and a number, boolean or pointer. State lives only in handles (tasks, channels, files, sockets, listeners, processes, HTTP clients). The Boehm collector frees the rest.
- **Loader.** A `.agcb` file is untrusted. The loader checks all of it before anything runs (version, strings, indexes, registers, jump targets, a step check in every loop and every calling function). A file over 256 MiB is `agentica run: cannot read <file>`, any other bad file `agentica run: invalid bytecode: <reason>`; both exit with code 2.
- **Interpreter.** One loop runs instructions. Calls push frames on the task's own stack, never the C stack. A tail call (`return f(...)` to a user function) reuses the frame.
- **Tasks.** `Task.spawn` makes a green thread. One scheduler thread per logical core runs them from one queue (`--schedulers N` sets the count), 2000 steps per turn, so a busy loop cannot starve the others.
- **I/O and waits.** A blocking call (file, socket, `Task.sleep`) parks only its own task. A waiting `Channel.send` or `recv` parks its task until a value or a slot is ready. A timed `Task.await` waits on the task and a timer, and the first to wake decides.
- **JIT.** An experimental x86-64 JIT, off by default: `--jit on` compiles hot functions made only of moves, constants, Int arithmetic and compares, `==` and `!=`, jumps and returns. Other machines run the interpreter.
- **Limits.** `--max-steps N` stops a program with `RUNTIME-STEP-LIMIT` after N steps across all tasks (no limit by default). Calls nest at most 10,000 deep per task, then `RUNTIME-STACK-OVERFLOW` with the call stack (a repeated function on one line with its count). A tail call adds no depth.
- **Maps and lists.** `Map` is a persistent HAMT that keeps insertion order; `Map.put` copies only the path to its key. `List` is a persistent vector of 32 children per node plus a small tail: indexing takes at most four steps for a million items, n pushes cost O(n), and a list of only Ints or only Floats keeps 8 bytes per item. `take`, `drop` and `reverse` are O(n), `sort` O(n log n).
- **JSON.** `JSON.parse` uses yyjson, and the VM's own encoder writes. A parsed object keeps each key once and encodes keys sorted, so `JSON.encode(JSON.parse(text))` is canonical.
- **Standard modules.** `std/queue`, `std/http`, `std/binary`, `std/toml` and `std/bdd` are written in Agentica, embedded in the binary and linked into your bytecode like your own modules.

## What it is built on

Pinned git submodules in `vm/third_party/`, all built into the release binary, which needs no system library beyond the C library. A default Linux `make` links the system OpenSSL 3 and libgc instead (see [Getting started](/getting-started/)). The release archives ship the license notices in `licenses/`.

| Library | Purpose | License |
|---|---|---|
| Boehm GC (bdwgc) | Garbage collector for program values | Boehm-GC license (permissive) |
| yyjson | Reads JSON text for `JSON.parse` | MIT |
| libuv | Event loop, file and socket I/O, timers, processes and the thread pool | MIT, with BSD-2-Clause and ISC parts |
| OpenSSL 3.5 | TLS for `TLS.connect`, `TLS.listen` and HTTPS | Apache-2.0 |
| picohttpparser | Parses HTTP start lines and headers | MIT (dual MIT or Perl license) |

The Unicode tables (case mapping, printing) are generated from the Unicode Character Database into the VM source, under the Unicode License v3.

## Learn more

The [VM design documents](../../docs/vm/README.md) in the repository give the reasons behind each choice.
