---
title: System, Time and Random
weight: 5
description: Program arguments, environment variables, exit codes, clocks and random numbers.
---

## System.args

```text
System.args() -> List[String]
```

Gives the words after the file name: `agentica tool.agc a b` gives `["a", "b"]`.

```agentica
def main() -> Void
  args = System.args()
  puts("#{args.size} arguments")
end
```

```output
0 arguments
```

## System.exit

```text
System.exit(code: Int) -> Void
```

Ends the program at once, with an exit code.

```agentica
def main() -> Void
  puts("before")
  System.exit(3)
  puts("never printed")
end
```

```output
before
```

## System.env

```text
System.env(name: String) -> Result[String]
```

Reads an environment variable of the program. With `--deny-env` (or `--sandbox`) it returns an error that begins with `denied: --deny-env`. There is no call that lists all variables.

- A variable that is not set is an error. A variable set to the empty string is `ok("")`.
- A name that is empty, or has `=` or a NUL in it, is an error.
- A value that is not valid UTF-8 is not an error. Each byte that is not part of a valid UTF-8 sequence becomes U+FFFD.
- The home directory is `System.env("HOME")`.

```agentica
def main() -> Void
  editor = System.env("AGENTICA_EXAMPLE_NOT_SET").unwrap_or("vi")
  puts(editor)
  puts(System.env("A=B").ok?)
end
```

```output
vi
false
```

The VM hides the variables it keeps for itself:

- `AGENTICA_CHANNEL`, and `UV_USE_IO_URING` when the VM set it. A program started with `Process.spawn` does not get them either.
- `AGENTICA_VM_METRICS` and `AGENTICA_VM_METRICS_FILE` are reserved for the VM metrics. A program started with `Process.spawn` does not get them, but `System.env` still shows them to your program.

## System.os

```text
System.os() -> String
```

The operating system of the running program. It needs no flag.

- `"linux"`, `"macos"` or `"windows"`.
- On any other system, the lowercase name that `uname` gives.
- `"unknown"` when the system cannot say, or when the name is not printable ASCII.

```agentica
def main() -> Void
  puts(System.os().length > 0)
end
```

```output
true
```

## System.pid

```text
System.pid() -> Int
```

The process id of the running program. It needs no flag. Pass it to `--driver-pid` when you start a VM. That VM then checks that its parent is this program.

```agentica
def main() -> Void
  puts(System.pid() > 0)
end
```

```output
true
```

## Std.source

```text
Std.source(path: String) -> Result[String]
```

The text of a `std/` source that the `agentica` binary carries, by its exact path in `stdlib/`: `"queue.agc"`, `"bdd/gherkin.agc"`, `"prelude/list.agc"`; `"internal/compiler/..."` is the private core of the front end that `std/analysis` uses. Any other path is an error, `"std/queue.agc"` and `"queue"` included. It needs no flag and reads only data of the binary, so tasks may call it at the same time. A doc or lint tool can read the std sources of the binary that runs it this way.

```agentica
def main() -> Void
  text = Std.source("queue.agc").unwrap_or("")
  puts(text.starts_with?("## "))
  puts(Std.source("nope.agc").ok?)
end
```

```output
true
false
```

## FrontEnd

`FrontEnd.hand_off(program, options, arguments)`, `FrontEnd.std_source(path)` and `FrontEnd.stdin_bytes()` belong to the front end of the `agentica` binary. That binary compiles a program and hands it to the VM: `hand_off` takes the compiled program (a `Bytes`) and runs it in a new runtime with the given VM options and arguments, `std_source` reads an embedded `std/` source by its path in `stdlib/`, and `stdin_bytes` reads standard input to its end as a `Result[Bytes]` (an error over 16 MiB or when the read fails; a later call reads on from there). They are not for your programs: a program that calls them, and any front end run by `agentica run`, stops with `RUNTIME-FRONT-END-ONLY`. They need no flag.

## Time.now_ms

```text
Time.now_ms() -> Int
```

Wall-clock time in milliseconds since 1970. It can jump when the system clock changes.

```agentica
def main() -> Void
  puts(Time.now_ms() > 1700000000000)
end
```

```output
true
```

## Time.monotonic_ms

```text
Time.monotonic_ms() -> Int
```

Milliseconds from an unknown start. The value never goes back. Use it to measure how long something takes.

```agentica
def main() -> Void
  start = Time.monotonic_ms()
  Task.sleep(5)
  elapsed = Time.monotonic_ms() - start
  puts(elapsed >= 5)
end
```

```output
true
```

## Time.monotonic_ns

```text
Time.monotonic_ns() -> Int
```

Nanoseconds from the same clock and the same unknown start as `Time.monotonic_ms`. They never go back. Use it for work too short for milliseconds. An `Int` holds about 292 years of nanoseconds, so the value does not overflow in practice.

```agentica
def main() -> Void
  start = Time.monotonic_ns()
  Task.sleep(5)
  elapsed = Time.monotonic_ns() - start
  puts(elapsed >= 4000000)
end
```

```output
true
```

## Random.int

```text
Random.int(min: Int, max: Int) -> Int
```

A random `Int` from `min` to `max`, uniform. Both are included. `min > max` stops the program with `RUNTIME-INVALID-RANGE`.

```agentica
def main() -> Void
  roll = Random.int(1, 6)
  puts(roll >= 1 and roll <= 6)
end
```

```output
true
```

## Random.float

```text
Random.float() -> Float
```

A random `Float` from `0.0` up to, but not including, `1.0`.

```agentica
def main() -> Void
  x = Random.float()
  puts(x >= 0.0 and x < 1.0)
end
```

```output
true
```

Each run gives other numbers. Run with `agentica --seed 42 file.agc` to get the same numbers every time (`N` is `0 .. 2147483647`, otherwise the exit status is 2). Without `--seed`, the generator is seeded from the operating system.

- Each task has its own generator. It is split from its parent when the task is spawned, so each task repeats its own numbers: the main task starts from the seed, and each spawn takes one draw from its parent. Timers, I/O and more than one scheduler can still change how tasks interleave, so a run of several tasks as a whole is not repeatable.
- Do not use `Random` for secrets: it is seeded, and `--seed` repeats it. Use [SecureRandom](/library/text-and-data/crypto/#securerandom) for keys, tokens and IDs.
