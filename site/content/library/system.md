---
title: System, Time and Random
weight: 7
description: Program arguments, exit codes, clocks and random numbers.
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
same numbers every time. The bytecode VM (`agentica --vm`) also repeats a
seeded run, but its numbers differ from the evaluator's for the same seed.
On the VM each task has its own generator, split from its parent when it
is spawned, so each task repeats its own numbers; on the evaluator all
tasks share one generator.
Do not use `Random` for secrets.
