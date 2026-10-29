---
title: Process
weight: 3
description: Start other programs, talk to them through their input and output, and wait for them.
---

A program can start other programs unless it runs with `--deny-run` (or `--sandbox`). Then every start returns an error that begins with `denied: --deny-run`, and extern blocks are refused as with `--deny-native`:

```sh
agentica --deny-run tool.agc
```

- Arguments go to the program as they are. No shell is involved. Every waiting function takes a timeout in milliseconds, and the spawn functions default it to 30000. `Process.spawn_captured` and `Process.spawn_channel` also default `dir` to `"."`; arguments fill from the left, so a timeout cannot be given without `dir`.
- A program you start belongs to the task that started it and stops when that task ends, however it ends. Programs still running stop when yours ends. [Task.spawn_owning](/library/concurrency/task/#taskspawn_owning) gives one to a new task.

## Process.spawn

```text
Process.spawn(command: String, args: List[String], timeout_ms: Int = 30000) -> Result[Process]
```

Starts a program with your program's environment.

- A name with no `/` (`"echo"`) is looked up in each `PATH` folder, in order. The current folder is never added and empty entries are skipped; a relative entry such as `bin` is looked up under the current folder, as in the shell.
- A command with `/` is a path (on Windows `\` and a drive such as `C:` too), relative to the current folder: run a local program as `"./tool"`.
- A name not found gives `error("process: executable is unavailable")`. A file that cannot run (no execute permission) is an error from `spawn`.
- An empty command, or a NUL byte in the command or an argument, gives `error("process: command must be nonempty and arguments cannot contain NUL")`.
- Windows: only `.exe` and `.com` run (`PATHEXT` is not read; a suffixless name tries `.exe` first; use `cmd.exe` by name for a shell). These fail: a name ending in a dot, a space, `.cmd` or `.bat`; one starting with `\\?\` or `\\.\`; a `:` that is not a drive.

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

Write to the program's standard input, and flush.

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

Read from the program's standard output.

- `read_line` removes the line ending. At the end of output it gives an error.
- `read_bytes` gives up to `count` bytes. At the end of output it gives `ok([])`.

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

Gives the exit code (`false` gives `ok(1)`). A timeout leaves the program running. Unread output stays readable after `wait`.

## Process.close

```text
Process.close(p: Process) -> Void
```

Stops the program if it still runs and frees it. Closing twice is fine.

For a `Process.spawn` program, the closing task waits up to one second for it to end; other tasks keep running.

Its standard error goes to yours, unless started with `Process.spawn_captured`. It goes through your program's stderr buffer: while nobody reads your stderr, the child and `Process.wait` on it wait, and other tasks keep running.

## Process.spawn_captured

```text
Process.spawn_captured(command: String, args: List[String], dir: String = ".", timeout_ms: Int = 30000) -> Result[Process]
```

Starts a program in the folder `dir` (`"."`, the default, is the current one) and keeps its output. The command is found as for `Process.spawn`, from the current folder, not from `dir`.

- Standard output and error are read all the time into buffers of 1 MiB each, so the program never blocks on a full pipe and its standard error is never printed. `read_line` and `read_bytes` read standard output as usual.
- Past 1 MiB of waiting standard output, or of standard error, the rest is dropped and every read of standard output gives `error("process: output exceeds 1048576 bytes")`. `Process.read_bytes(p, 0, timeout)` gives it at once, to check without waiting.
- `close` sends `SIGTERM` and kills the program one second later if it still runs, so an Agentica program can stop its own children. Windows has no `SIGTERM`: the program ends at once, and where libuv can assign its job object, programs the VM started die when the VM ends (other descendants are not covered).

## Process.output

```text
Process.output(p: Process, timeout_ms: Int) -> Result[ProcessOutput]
```

Waits until a captured program has closed its standard output and error, then gives `ProcessOutput(stdout: String, stderr: String, truncated: Bool)`: `stdout` is what you have not read yet, `stderr` all of it, `truncated` says whether output was dropped. It consumes nothing, so call it again if needed. A `Process.spawn` program gives `error("process: output is not captured")`.

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
Process.spawn_channel(command: String, args: List[String], dir: String = ".", timeout_ms: Int = 30000) -> Result[Process]
```

Like `Process.spawn_captured`, and also opens a private channel to the program, apart from its standard input, output and error. It carries lines of text both ways, on Linux, macOS and Windows.

| System | Channel | The program sees |
|---|---|---|
| Linux, macOS | a socket pair | descriptor 3, `AGENTICA_CHANNEL=3` |
| Windows | a pipe each way | reads 3, writes 4, `AGENTICA_CHANNEL=3,4` |

`Process.spawn` and `Process.spawn_captured` remove that variable from what they pass on, so a program sees only a channel its own parent opened. Its standard input and output stay free.

## Process.channel_read_line, Process.channel_send and Process.channel_close

```text
Process.channel_read_line(p: Process, timeout_ms: Int) -> Result[String]
Process.channel_send(p: Process, text: String, timeout_ms: Int) -> Result[Void]
Process.channel_close(p: Process, timeout_ms: Int) -> Result[Void]
```

- `channel_read_line` reads one line (at most 1 MiB, ending removed), as `Process.read_line` does. At the end it gives `error("process: end of input")`. If standard output or error was cut (see `Process.read_available`) and no complete line is there, it gives `error("process: output exceeds 1048576 bytes")` at once, so a program that prints forever is noticed without the timeout.
- `channel_send` sends at most 1048576 bytes exactly as given: add your own `"\n"`.
- `channel_close` closes only the sending side: the program reads end of input, and you can still read what it sends. Closing twice, or after exit, is fine.
- A timeout in `channel_read_line` or `channel_send` closes the channel, not the program. Later calls give `error("process: channel is closed")`.
- Without a channel all three give `error("process: the child has no channel")`.

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

Gives, and removes, the standard output of a captured program that has arrived since the last call.

- It never waits for more output; the timeout only bounds the wait for the read lock. One call takes at most about 2 MiB.
- Bytes that end mid-character wait for the next call, so a character is never split (unless the output has ended).
- Output written before a channel line is in the text once you have read that line, so flushing before sending a record ties the output to the record.
- After truncation it gives `error("process: output exceeds 1048576 bytes")`. On a `Process.spawn` program, `error("process: output is not captured")`.

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

The program's side of the channel its parent opened with `Process.spawn_channel`, with the rules of `channel_read_line` and `channel_send`. The timeout must be positive, and a timeout closes the channel for good. Without a channel: `error("process: no parent channel")`.

- The VM takes the channel at start-up only when `AGENTICA_CHANNEL` has the system's value (`3`, or `3,4` on Windows). Unix: descriptor 3 must be a socket or a FIFO open for reading and writing. Windows: 3 a readable pipe, 4 a writable one. Anything else (a regular file, a device, a one-way FIFO) is left alone: no channel.
- The program's own children do not inherit the descriptors or the variable.

These calls are for runner code such as `agentica test`. A test that calls them can break the protocol between the runner and its file, and nothing stops it.

```agentica {mode="check"}
def main() -> Void
  line = Process.parent_read_line(5000)
  if line.ok?
    sent = Process.parent_send("echo " + line.unwrap! + "\n", 5000)
  end
end
```
