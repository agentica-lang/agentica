---
title: Design decisions
weight: 6
description: The main design decisions of Agentica and its bytecode VM, Aurora, and why each one was taken.
---

Agentica is a small, statically typed language for AI agents. Its programs run on Aurora, a bytecode virtual machine written in C11.

## Two parts: a front end in Agentica and a C VM

**Decision.** The front end (lexer, parser, checker and lowering to bytecode) is written in Agentica and compiled to bytecode like any program. A C11 VM runs every program, the front end included; the two are one binary, with no other backend.

**Why.** Users need no second language or toolchain, and start-up matters more than peak speed, because agents write, run and repair in a loop. A front end written in the language it compiles is checked by its own fixed point: it compiles itself to the same bytes.

## Immutable values, with state in handles

**Decision.** Strings, lists, maps, structs, enums and results never change in place. The only mutable state lives in handles, such as tasks, channels, files, sockets and processes.

**Why.** Tasks share immutable values without locks or copies, also once more threads arrive (planned). Each handle has one owner task, which decides who closes it.

## Garbage collection with Boehm

**Decision.** The VM frees program values with the Boehm GC (bdw-gc). Linux builds use the system copy by default. The release links its own static copy.

**Why.** No manual frees or reference counts, so immutable values are shared freely. The collector scans memory conservatively, so the VM never tags its pointers, and the static copy keeps the release at glibc only.

## Green tasks on one scheduler

**Decision.** `Task.spawn` makes a green task with its own registers and frames. A scheduler runs tasks in turns of 2000 steps, and a blocking call parks only its own task. One scheduler thread runs all tasks today; more are planned.

**Why.** Calls push frames on the task's own stack, never the C stack, so a switch changes only the current task. The turn limit stops a busy loop from starving the others; a parked task lets a slow read wait alone.

## One libuv event loop for I/O

**Decision.** One libuv loop handles sockets, timers, child processes and the standard streams; regular files use its thread pool. A print copies its text into a buffer of 64 KiB per stream, so a slow reader stalls only the tasks that print. The loop runs on Linux, macOS and Windows.

**Why.** libevent had no file I/O, no UTF-8 paths on Windows and no spawn with stdio pipes; libuv has all three. The pool runs only bounded work, because a pool thread that waits forever cannot be cancelled or joined.

## Results and try, not exceptions

**Decision.** Errors are `Result[T]` values. `try` returns the error from the current function, and there is no `raise` or `rescue`. Only user enums take type parameters, besides the builtin `List`, `Map` and `Result`.

**Why.** An error is a return value, and every `try` shows where a function can leave. Agents do best with one obvious form for each job. User generics are still an open design.

## Step limits and an untrusted bytecode loader

**Decision.** The loader checks the whole `.agcb` file before anything runs, and it treats the file as untrusted. Every loop and call charges a step, so `--max-steps` stops a runaway program. The end-of-run file flush has a 30-second limit by default.

**Why.** A bad file must not cause memory errors, and it must still stop under the step limit. The exit path is bounded because a blocked read once hung the VM at exit, and a FIFO with no reader must not keep the run open. Step limits bound instructions, not memory, so a heap cap is still an open question.

## Third-party libraries: few, pinned and permissive

**Decision.** The VM uses five vendored libraries, each a git submodule pinned to a release tag: Boehm GC, yyjson, libuv, OpenSSL and picohttpparser. Each must be permissive, with no copyleft.

**Why.** The release links them into one binary that needs only glibc. Statically linked code must be permissive, and each license ships with the release.

## Learn more

For how a program runs, see [The Aurora VM](/vm/). The full design is in the [VM design documents](../../docs/vm/README.md) of the repository.
