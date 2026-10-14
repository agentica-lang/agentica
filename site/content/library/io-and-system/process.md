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

## Process.spawn_channel

```text
Process.spawn_channel(command: String, args: List[String], dir: String, timeout_ms: Int) -> Result[Process]
```

Starts a program like `Process.spawn_captured`, and also opens a channel to it: a bidirectional socket pair, apart from its standard input, standard output and standard error, that carries lines of text in both directions. Linux only.

The program finds the channel on file descriptor 3, and its environment holds `AGENTICA_CHANNEL=3`. `Process.spawn` and `Process.spawn_captured` remove that variable from the environment they pass on, so a program only sees a channel that its own parent opened for it.

A program that talks to its parent on a channel keeps its own standard input and output for itself. `agentica test` uses one for the unit test files and BDD scenarios it runs.

## Process.channel_read_line, Process.channel_send and Process.channel_close

```text
Process.channel_read_line(p: Process, timeout_ms: Int) -> Result[String]
Process.channel_send(p: Process, text: String, timeout_ms: Int) -> Result[Void]
Process.channel_close(p: Process, timeout_ms: Int) -> Result[Void]
```

`channel_read_line` reads one line the program sent, as `Process.read_line` does: at most 1 MiB, with the line ending removed, and `error("process: end of input")` when the channel has ended. `channel_send` sends at most 1048576 bytes, exactly as given, so add your own `"\n"`. `channel_close` closes only the sending side: the program reads the end of its input, and you can still read what it sends. Closing twice is fine, and so is closing after the program has exited.

When the program's standard output or standard error is cut (see `Process.read_available`), a `channel_read_line` that finds no complete line gives `error("process: output exceeds 1048576 bytes")` at once, so a program that prints for ever is noticed without waiting for the timeout. A timeout in `channel_read_line` or `channel_send` closes the channel, and only the channel: the program keeps running, and later channel calls give `error("process: channel is closed")`. On a program started without a channel, the three give `error("process: the child has no channel")`.

```agentica {mode="check"}
def main() -> Void
  script = "read line <&3; echo \"got $line\" >&3"
  p = Process.spawn_channel("sh", ["-c", script], ".", 1000).unwrap!
  sent = Process.channel_send(p, "hello\n", 1000)
  puts(Process.channel_read_line(p, 1000))
  Process.close(p)
end
```

```text
ok("got hello")
```

## Process.read_available

```text
Process.read_available(p: Process, timeout_ms: Int) -> Result[String]
```

Gives the standard output of a captured program that has arrived since the last call, and removes it. It never waits for more output; the timeout only bounds the wait for the read lock. One call takes at most about 2 MiB, so call it again for the rest. When the arrived bytes end in the middle of a UTF-8 character, the incomplete bytes stay for the next call, so a character is never split between two calls (unless the output has ended). What the program wrote to its standard output before it wrote a line on the channel is in the text once you have read that line, so a program that flushes its output before it sends a record has that output tied to the record.

After the output was truncated it gives `error("process: output exceeds 1048576 bytes")`, and on a program from `Process.spawn` it gives `error("process: output is not captured")`.

```agentica {mode="check"}
def main() -> Void
  script = "echo working; echo done >&3"
  p = Process.spawn_channel("sh", ["-c", script], ".", 1000).unwrap!
  puts(Process.channel_read_line(p, 1000))
  puts(Process.read_available(p, 1000))
  Process.close(p)
end
```

```text
ok("done")
ok("working\n")
```

## Process.parent_read_line and Process.parent_send

```text
Process.parent_read_line(timeout_ms: Int) -> Result[String]
Process.parent_send(text: String, timeout_ms: Int) -> Result[Void]
```

The program's side of the channel its parent opened with `Process.spawn_channel`. The rules are those of `channel_read_line` and `channel_send`, and the timeout must be positive. A program that was not given a channel gets `error("process: no parent channel")`. A timeout closes the channel for good.

The VM takes the channel when it starts, and only when `AGENTICA_CHANNEL=3` is set and descriptor 3 is a socket, or a FIFO opened for reading and writing. A regular file, a device or a one-way FIFO on descriptor 3 is left alone and the program has no channel. The VM hides the descriptor and removes the variable, so the program's own children do not inherit either.

These two calls are for runner code such as `agentica test`. A test or step that calls them can break the protocol between the runner and its file, and nothing stops it.

```agentica {mode="check"}
def main() -> Void
  line = Process.parent_read_line(5000)
  if line.ok?
    sent = Process.parent_send("echo " + line.unwrap! + "\n", 5000)
  end
end
```
