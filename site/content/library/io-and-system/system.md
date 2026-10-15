---
title: System, Time and Random
weight: 5
description: Program arguments, environment variables, exit codes, clocks and random numbers.
---

## System.args

```text
System.args() -> List[String]
```

Gives the words after the file name: `agentica tool.agc a b` gives
`["a", "b"]`.

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

Ends the program with an exit code at once.

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

Reads an environment variable of the program. A variable that is not set is an error, and a variable set to the empty string is `ok("")`. A name that is empty or has `=` or a NUL in it is an error too. A value that is not valid UTF-8 is not an error: each byte that is not part of a valid UTF-8 sequence becomes U+FFFD. The home directory is `System.env("HOME")`. No flag is needed, and there is no call that lists all variables.

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

The VM hides the variables it keeps for itself: `AGENTICA_CHANNEL`, and `UV_USE_IO_URING` when the VM set it. A program started with `Process.spawn` does not get them either. It also does not get `AGENTICA_VM_METRICS` and `AGENTICA_VM_METRICS_FILE`, which are reserved for the metrics of the VM (a later phase); `System.env` still shows them to your program.

## System.pid

```text
System.pid() -> Int
```

The process id of the running program. It needs no flag. Pass it when you start a VM with `--driver-pid`, which makes that VM check that its parent is this program.

```agentica
def main() -> Void
  puts(System.pid() > 0)
end
```

```output
true
```

## FrontEnd

`FrontEnd.hand_off` and `FrontEnd.std_source` belong to the front end of the `agentica` binary, which compiles a program and hands it to the VM. They are not for your programs: a program that calls them stops with `RUNTIME-FRONT-END-ONLY`.

## Time.now_ms

```text
Time.now_ms() -> Int
```

Wall-clock time in milliseconds since 1970. It can jump when the system clock
changes.

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

Milliseconds from an unknown start that never go back. Use it to measure how
long something takes.

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

Nanoseconds from the same clock and the same unknown start as `Time.monotonic_ms`; they never go back. Use it for work too short for milliseconds. An `Int` holds about 292 years of nanoseconds, so the value does not overflow in practice.

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

A random `Int` from `min` to `max`, both included.

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

Each run gives other numbers. Run with `agentica --seed 42 file.agc` to get the
same numbers every time. Each task has its own generator, split from its
parent when it is spawned, so each task repeats its own numbers.
Do not use `Random` for secrets.
