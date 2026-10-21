---
title: Design decisions
weight: 7
description: The main design decisions of Agentica and its bytecode VM, Aurora, and why each one was taken.
---

Agentica is a small, statically typed language for AI agents. Its programs run on Aurora, a bytecode virtual machine written in C11.

## Two parts: a front end in Agentica and a C VM

**Decision.** The front end is written in Agentica and compiled to bytecode like any program. A C11 VM runs every program, the front end included, in one binary with no other backend.

**Why.** No second language or toolchain for users, and start-up matters more than peak speed, because agents write, run and repair in a loop. A front end in its own language is checked by its fixed point: it compiles itself to the same bytes.

## Immutable values, with state in handles

**Decision.** Strings, lists, maps, structs, enums and results never change in place. Mutable state lives only in handles (tasks, channels, files, sockets, processes), and each handle has one owner task, which decides who closes it.

**Why.** Tasks share immutable values without locks or copies, also across scheduler threads once several schedulers open.

## Garbage collection with Boehm

**Decision.** The Boehm GC frees program values. Linux builds use the system copy by default; the release links its own static copy on every system.

**Why.** No manual frees or reference counts, so values are shared freely. The collector scans conservatively, so pointers need no tags, and the static copy keeps the Linux release at glibc only.

## Green tasks on schedulers

**Decision.** A green task has its own registers and frames, and a blocking call parks only its task. By default one scheduler thread runs all tasks, in turns of 2000 steps. N scheduler threads with one I/O thread (`--schedulers N`) are built and tested, but stay behind a test switch until they open to everyone.

**Why.** Frames live on the task's stack, not the C stack, so a switch changes only the current task. The turn limit stops a busy loop starving the others, and a slow read waits alone.

## One libuv event loop for I/O

**Decision.** One libuv loop handles sockets, timers, child processes and the standard streams; regular files use its thread pool. With several schedulers the loop runs on its own I/O thread. A print copies its text into a 64 KiB buffer per stream, so a slow reader stalls only the tasks that print. It runs on Linux, macOS and Windows.

**Why.** libevent had no file I/O, no UTF-8 paths on Windows and no spawn with stdio pipes; libuv has all three. The pool runs only bounded work, because a pool thread that waits forever cannot be cancelled or joined.

## Results and try, not exceptions

**Decision.** Errors are `Result[T]` values and `try` returns the error from the current function. There is no `raise` or `rescue`. Only user enums take type parameters, besides the builtin `List`, `Map` and `Result`.

**Why.** Every `try` shows where a function can leave, and agents do best with one obvious form per job. User generics are still an open design.

## Step limits and an untrusted bytecode loader

**Decision.** The loader checks the whole `.agcb` file before anything runs. Every loop and call charges a step, so `--max-steps` stops a runaway program. The end-of-run file flush is limited to 30 seconds by default.

**Why.** A bad file must not cause memory errors and must still stop at the step limit. A blocked read once hung the VM at exit, and a FIFO with no reader must not keep the run open. Step limits bound instructions, not memory: a heap cap is still open.

## Third-party libraries: few, pinned and permissive

**Decision.** Five libraries, each a submodule pinned to a release tag: Boehm GC, yyjson, libuv, OpenSSL, picohttpparser. Each must be permissive, with no copyleft.

**Why.** The release links them into one binary per system (on Linux it needs only glibc), so they must be permissive, and each license ships with it.

## Learn more

For how a program runs, see [The Aurora VM](/vm/). The full design is in the [VM design documents](../../docs/vm/README.md) of the repository.
