---
title: Getting started
weight: 1
description: Install Agentica, run your first program, check it and read its errors.
---

## Install

{{% release %}}

Agentica programs run on a bytecode VM written in C. The `agentica` command checks a program and compiles it to bytecode with a front end written in [Racket](https://racket-lang.org/), then runs it on the VM.

To build from source you need Racket CS 9.3 or newer, a C11 compiler (gcc or clang) and `make`. On Linux the VM also needs OpenSSL 3, the Boehm GC (libgc 8.2 or newer) and `pkg-config` (Debian and Ubuntu: `libssl-dev libgc-dev pkg-config`); `make vm AGENTICA_GC=vendored` builds the Boehm GC from its submodule instead, which needs nothing else; `make vm AGENTICA_OPENSSL=vendored` builds OpenSSL from its submodule instead, which needs Perl 5 and takes a few minutes; pass either setting to every make command, or export it (`export AGENTICA_GC=vendored`). Get the source with the VM's third-party libraries, and build the `agentica` command:

```sh
git clone https://github.com/sonic182/agentica.git
cd agentica
git submodule update --init
make exe
```

This writes `dist/agentica` and the VM next to it, `dist/agentica-vm`. A default source build links the system OpenSSL, so `dist/` runs only on machines that have it; the release archive is portable, since its VM has OpenSSL built in. Put that directory on your `PATH`, or call the command by its full path. You can also skip `make exe`: after `make vm`, `racket src/main.rkt file.agc` does the same as `agentica file.agc`, with the VM from `dist/`.

The release archive for Linux x86-64 needs none of these tools: it bundles Racket and `agentica-vm`, and runs on glibc 2.28 or newer.

## Hello, world

Save this as `hello.agc`:

```agentica
def main() -> Void
  puts("Hello, world!")
end
```

Run it:

```sh
agentica hello.agc
```

```output
Hello, world!
```

Every program has one `main() -> Void` function. Running the file calls it.
`puts` prints a value and a new line.

## Program arguments

Words after the file name reach the program through `System.args()`:

```agentica {mode="check"}
def main() -> Void
  for name in System.args()
    puts("Hello, #{name}!")
  end
end
```

```sh
agentica greet.agc Ana Bob
```

```text
Hello, Ana!
Hello, Bob!
```

## Check without running

`agentica check` reads the program and checks its types, but does not run it:

```sh
agentica check hello.agc
```

```text
check ok
```

Agentica also checks every program before it runs it, so a type error never
happens halfway through a run.

## Read an error

Here is a program with a mistake. `count` starts as an `Int`, so it cannot
become a `String` later:

```agentica {expect="CHECK-TYPE-MISMATCH"}
def main() -> Void
  count = 1
  count = "two"
  puts(count)
end
```

The checker stops at the first error. It prints where it is, a stable code in
brackets, and often a `help` line with the fix:

```text
bad.agc:3:11 error[CHECK-TYPE-MISMATCH]
expected Int, found String

3 |   count = "two"
  |           ^^^^^
  = help: convert it with String.to_int!(...)
```

The exit code is `1` when the program has an error, and `2` when the command is
wrong or the file cannot be read. Error codes start with the stage that found
them: `LEX-`, `PARSE-`, `CHECK-` or `RUNTIME-`.

## Errors for tools and agents

`--ai` prints the same error as short labeled lines, and `--json` prints it as
one JSON object. Both are easy for other programs to read:

```sh
agentica --json bad.agc
```

```text
{"actual":"String","code":"CHECK-TYPE-MISMATCH","expected":"Int","file":"bad.agc","function":"main() -> Void","help":"convert it with String.to_int!(...)","message":"expected Int, found String","range":{"end":{"column":16,"line":3},"start":{"column":11,"line":3}}}
```

A runtime error also prints the call stack of the task that failed, innermost call first, in all three formats. It shows when the task has more than one frame or is not `main`; a failure directly in `main` has no stack.

```text
nested.agc:2:13 error[RUNTIME-INDEX-OUT-OF-RANGE]
index 5 is outside a list of length 3

2 |   return xs[i] + 1
  |             ^
  = stack, innermost first:
    pick at nested.agc:2:13
    load at nested.agc:6:10
    main at nested.agc:11:8
```

Each line is a function and the place where it was running: the error for the first line, and the call it waits on for the others. A block shows as `block`. A frame that a tail call replaced is gone, and the frame left ends with `(after a tail call)`. A recursion that repeats the same call is one line with a count, such as `walk at tree.agc:9:12 (9998 times)`. After that, at most 20 lines show: the 15 innermost, a line `... 312 frames not shown ...`, and the 5 outermost. The stack of a task ends with `task spawned at file:line:column`, the place of its `Task.spawn` call. A function name or file path longer than 256 bytes is cut there, at a character boundary, and ends with `...`. With `--ai` the same lines come under `stack:`, and with `--json` they are the `stack` array of the object, plus `stack_omitted` and, for a task, `spawned_at`. A runtime error names each file as you can open it from the working directory (`examples/hello.agc` and `examples/lib/util.agc` for `agentica examples/hello.agc`), and a standard module as `std/queue.agc`. The bytecode stores names relative to the folder of the first file, so it is the same wherever the program was built; `agentica-vm` alone prints those names.

## Look up a builtin

`agentica help NAME` prints the signature and a short description of a builtin function. Add `--json` for a JSON object. `agentica help` with no name lists the commands and the builtin namespaces, and `agentica --help` adds the options and a few core rules.

```sh
agentica help String.split
```

```text
String.split(s: String, separator: String) -> List[String]
Split text; an empty separator gives characters.
```

## Other options

| Option | Does |
|---|---|
| `--max-steps N` | stops the program after `N` steps (`RUNTIME-STEP-LIMIT`) |
| `--seed N` | makes `Random` repeat the same numbers |
| `--flush-timeout MS` | waits at most `MS` milliseconds for file data and buffered output to be written at the end of the run; when time runs out, the run still ends and prints a warning. The default is 30000 and the most is 86400000 (24 hours). The environment variable `AGENTICA_FLUSH_TIMEOUT_MS` sets the same value, and the flag wins over it |
| `--allow-run` | lets the program start other programs with `Process.spawn` |
| `--dump` | prints the checked program tree instead of running it |
| `--dump-ir` | prints the lowered VM IR instead of running the program |
| `compile FILE -o OUT` | writes the program as VM bytecode; `agentica-vm -- OUT` runs it |
| `--version` | prints the version |

`agentica test` runs unit test files (`*_test.agc`, see [Test](/library/testing/test/)) and `.feature` specifications (see [BDD](/library/testing/bdd/)) in one report. With no paths it looks in `test/` and `specs/`; `--only TEXT` runs the tests and scenarios whose name contains `TEXT`.

```sh
agentica test
agentica test test/ports_test.agc --only port
```

Programs run on a bytecode VM.

## Next

Take the [language tour](/tour/), starting with
[values and types](/tour/values-and-types/).
