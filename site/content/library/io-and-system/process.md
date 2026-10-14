---
title: Process
weight: 3
description: Start other programs, talk to them through their input and output, and wait for them.
---

A program can start other programs only when it runs with `--allow-run`:

```sh
agentica --allow-run tool.agc
```

[BDD](/library/testing/bdd/) steps can always start programs: `agentica test` runs
each scenario with `--allow-run`, and `agentica test --allow-run` only lets the
programs under test start programs too.

Arguments go to the program as they are, with no shell. Every function that
waits takes a timeout in milliseconds. Programs that are still running are
stopped when your program ends. The examples here start real programs, so they
are checked but not run.

## Process.spawn

```text
Process.spawn(command: String, args: List[String], timeout_ms: Int) -> Result[Process]
```

Starts a program. A name with no `/`, such as `"echo"`, is looked up in each
`PATH` folder in order. The current folder is never added (empty `PATH`
entries are skipped), but a relative entry such as `.` or `bin` is looked up
under the current folder, as in the shell. A command with `/` is a path,
relative to the current folder unless it starts with `/`, so a program in the
current folder runs as `"./tool"`. A name that is not found gives
`error("process: executable is unavailable")`. On Windows only `.exe` and
`.com` programs can be spawned.

A file that is found but cannot run (no execute permission, say) is an error
from `spawn`.

An empty command, or a command or argument with a NUL byte, gives `error("process: command must be nonempty and arguments cannot contain NUL")`.

The program gets your program's environment.

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

Output that the program wrote and you have not read stays readable after `wait`.

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

Stops the program if it still runs, and frees it. Closing twice is fine. The task that closes a program started with `Process.spawn` waits until it has ended, for one second at most, and other tasks keep running meanwhile.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn("sleep", ["10"], 1000).unwrap!
  Process.close(p)
  puts("stopped")
end
```

The program's standard error goes straight to your program's standard error,
unless you start it with `Process.spawn_captured`.

## Process.spawn_captured

```text
Process.spawn_captured(command: String, args: List[String], dir: String, timeout_ms: Int) -> Result[Process]
```

Starts a program in the folder `dir` (`"."` is the current folder) and keeps
its output: standard output and standard error are read all the time into
buffers of 1 MiB each, so the program never blocks on a full pipe, and its
standard error is never printed. `Process.read_line` and `Process.read_bytes`
read standard output as usual. The command is found as for `Process.spawn`,
from the current folder, not from `dir`.

When more than 1 MiB of standard output is waiting, or standard error passes
1 MiB, the rest is dropped and every read of standard output gives
`error("process: output exceeds 1048576 bytes")`. `Process.read_bytes(p, 0,
timeout)` gives that error at once, so you can check for it without waiting.

Closing a captured program asks it to stop first (`SIGTERM`) and kills it one second later if it still runs, so a program that is itself an Agentica program can stop its own children. `agentica test` runs each [BDD](/library/testing/bdd/) scenario, and each program under test, as a captured program.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn_captured("pwd", [], "/", 1000).unwrap!
  puts(Process.read_line(p, 1000))
  Process.close(p)
end
```

```text
ok("/")
```

## Process.output

```text
Process.output(p: Process, timeout_ms: Int) -> Result[ProcessOutput]
```

Waits until a captured program has closed its standard output and standard
error, and gives `ProcessOutput(stdout: String, stderr: String, truncated:
Bool)`: the standard output you have not read yet, all of standard error, and
whether some output was dropped. It reads nothing away, so you can call it
again. A program from `Process.spawn` gives
`error("process: output is not captured")`.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn_captured("sh", ["-c", "echo one; echo two; echo oops >&2"], ".", 1000).unwrap!
  puts(Process.read_line(p, 1000))
  out = Process.output(p, 1000).unwrap!
  puts(out.stdout)
  puts(out.stderr)
  puts(out.truncated)
  Process.close(p)
end
```

```text
ok("one")
two

oops

false
```
