---
title: Design decisions
weight: 6
description: The main design decisions of Agentica and its bytecode VM, Aurora, and why each one was taken.
---

Agentica is a small, statically typed language for AI agents. Its programs run on Aurora, a bytecode virtual machine written in C11. This page gives the main decisions and why each was taken.

## Two parts: a front end in Agentica and a C VM

**Decision.** The front end (lexer, parser, checker and lowering to bytecode) is written in Agentica and compiled to bytecode like any program. A C11 VM runs every program, including the front end, and there is no other backend. The two are one binary.

**Why.** Users need no second language or compiler toolchain, and start-up matters more than peak speed, because agents write, run and repair in a loop. A front end written in the language it compiles is checked by its own fixed point: it compiles itself to the same bytes. A small C VM can ship as one binary, with the front end and the standard modules inside.

## Immutable values, with state in handles

**Decision.** Strings, lists, maps, structs, enums and results never change in place. The only mutable state lives in handles, such as tasks, channels, files, sockets and processes.

**Why.** Tasks can share an immutable value without locks or copies, and this still holds when more threads arrive (planned). Each handle has one owner task, which decides who closes it.

## Garbage collection with Boehm

**Decision.** The VM frees program values with the Boehm GC (bdw-gc). Linux builds use the system copy by default. The release links its own static copy.

**Why.** The collector frees memory without manual frees or reference counts, so immutable values can be shared freely. It scans memory conservatively, so the VM never tags its pointers. The static copy means the release needs only glibc.

## Green tasks on one scheduler

**Decision.** `Task.spawn` makes a green task with its own registers and frames. A scheduler runs tasks in turns of 2000 steps, and a blocking call parks only its own task. One scheduler thread runs all tasks today; more are planned.

**Why.** Calls push frames on the task's own stack and never recurse on the C stack, so a task switch changes only the current task. The turn limit stops a busy loop from starving the others, and a parked task lets a slow read wait without stalling the rest.

## One libuv event loop for I/O

**Decision.** One libuv loop handles sockets, timers, child processes, stdin, stdout and stderr. Regular files use its thread pool. A print copies its text into a buffer of 64 KiB per stream and the loop writes it, so a slow reader stalls only the tasks that print. This is Linux only for now.

**Why.** libevent had no file I/O, no UTF-8 paths on Windows and no spawn with stdio pipes. libuv has all three. The pool runs only bounded work, because a pool thread that waits forever cannot be cancelled or joined.

## Results and try, not exceptions

**Decision.** Errors are `Result[T]` values. `try` returns the error from the current function, and there is no `raise` or `rescue`. Only user enums take type parameters, besides the builtin `List`, `Map` and `Result`.

**Why.** An error is a return value, and every `try` shows where it can leave a function. LLM agents do best with one obvious form for each job. User generics are still an open design.

## Step limits and an untrusted bytecode loader

**Decision.** The loader checks the whole `.agcb` file before anything runs, and it treats the file as untrusted. Every loop and call charges a step, so `--max-steps` stops a runaway program. The end-of-run file flush has a 30-second limit by default.

**Why.** A bad file must not cause memory errors, and with a step limit it must still stop. The exit path is bounded because a blocked read once hung the VM at exit. A FIFO whose reader has stopped must not keep the run open for ever. Step limits bound instructions, not memory, so a heap cap is still an open question.

## Third-party libraries: few, pinned and permissive

**Decision.** The VM uses five vendored libraries, each a git submodule fixed to a release tag: Boehm GC, yyjson, libuv, OpenSSL and picohttpparser. Each must have a permissive license, with no copyleft.

**Why.** The release links them into one binary that needs only glibc. Statically linked code must be permissive, and each license ships with the release.

## Learn more

See [The Aurora VM](/vm/) for how a program runs. The [VM design documents](../../docs/vm/README.md) in the Agentica repository have the full design and reasons.
