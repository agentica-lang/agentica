---
title: Process
weight: 11
description: Start other programs, talk to them through their input and output, and wait for them.
---

A program can start other programs only when it runs with `--allow-run`:

```sh
agentica --allow-run tool.agc
```

Arguments go to the program as they are, with no shell. Every function that
waits takes a timeout in milliseconds. Programs that are still running are
stopped when your program ends. The examples here start real programs, so they
are checked but not run.

## Process.spawn

```text
Process.spawn(command: String, args: List[String], timeout_ms: Int) -> Result[Process]
```

Starts a program. The command is found through `PATH`, or given as a path.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn("echo", ["hello"], 1000).unwrap!
  puts(Process.read_line(p, 1000))
  puts(Process.wait(p, 1000))
end
```

```text
ok("hello")
ok(0)
```

## Process.send and Process.send_bytes

```text
Process.send(p: Process, text: String, timeout_ms: Int) -> Result[Void]
Process.send_bytes(p: Process, bytes: List[Int], timeout_ms: Int) -> Result[Void]
```

Write to the program's standard input and flush.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn("cat", [], 1000).unwrap!
  sent = Process.send(p, "ping\n", 1000)
  puts(Process.read_line(p, 1000))
  Process.close(p)
end
```

```text
ok("ping")
```

## Process.read_line and Process.read_bytes

```text
Process.read_line(p: Process, timeout_ms: Int) -> Result[String]
Process.read_bytes(p: Process, count: Int, timeout_ms: Int) -> Result[List[Int]]
```

Read from the program's standard output. `read_line` removes the line ending
and gives an error at the end of output. `read_bytes` gives up to `count`
bytes, and `ok([])` at the end.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn("printf", ["ab"], 1000).unwrap!
  puts(Process.read_bytes(p, 10, 1000))
  code = Process.wait(p, 1000)
end
```

```text
ok([97, 98])
```

## Process.close_stdin

```text
Process.close_stdin(p: Process, timeout_ms: Int) -> Result[Void]
```

Closes the program's input, so it sees the end of input.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn("wc", ["-l"], 1000).unwrap!
  sent = Process.send(p, "a\nb\n", 1000)
  closed = Process.close_stdin(p, 1000)
  puts(Process.read_line(p, 1000).unwrap!.strip)
end
```

```text
2
```

## Process.wait

```text
Process.wait(p: Process, timeout_ms: Int) -> Result[Int]
```

Waits for the program to end and gives its exit code. A timeout leaves the
program running.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn("false", [], 1000).unwrap!
  puts(Process.wait(p, 1000))
end
```

```text
ok(1)
```

## Process.close

```text
Process.close(p: Process) -> Void
```

Stops the program if it still runs, and frees it. Closing twice is fine.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn("sleep", ["10"], 1000).unwrap!
  Process.close(p)
  puts("stopped")
end
```

The program's standard error goes straight to your program's standard error.
