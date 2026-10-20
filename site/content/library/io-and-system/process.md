---
title: Process
weight: 3
description: Start other programs, talk to them through their input and output, and wait for them.
---

A program can start other programs only when it runs with `--allow-run`:

```sh
agentica --allow-run tool.agc
```

[BDD](/library/testing/bdd/) steps can always start programs. `agentica test` runs each scenario with `--allow-run`. `agentica test --allow-run` only lets the programs under test start programs too.

- Arguments go to the program as they are. No shell is involved.
- Every function that waits takes a timeout in milliseconds.
- Programs still running are stopped when your program ends.
- The examples here start real programs, so they are checked but not run.
- A program you start belongs to the task that started it. It stops when that task ends, however it ends. [Task.spawn_owning](/library/concurrency/task/#taskspawn_owning) gives one to a task it starts.

## Process.spawn

```text
Process.spawn(command: String, args: List[String], timeout_ms: Int) -> Result[Process]
```

Starts a program. It gets your program's environment.

PATH lookup:

- A name with no `/`, such as `"echo"`, is looked up in each `PATH` folder, in order.
- The current folder is never added, and empty `PATH` entries are skipped. A relative entry such as `.` or `bin` is looked up under the current folder, as in the shell.
- A command with `/` is a path. On Windows, `\` and a drive such as `C:` also make a path. A path is relative to the current folder, unless it starts with `/`. So a program in the current folder runs as `"./tool"`.
- A name that is not found gives `error("process: executable is unavailable")`.
- A file that is found but cannot run, such as one without execute permission, is an error from `spawn`.

Windows:

- Only `.exe` and `.com` programs can be spawned. `PATHEXT` is not read, and `.bat` and `.cmd` never run. Start `cmd.exe` by name to use a shell.
- A name with no suffix tries `.exe` before `.com`.
- These fail: a name that ends in a dot, a space, `.cmd` or `.bat`; a name that starts with `\\?\` or `\\.\`; a `:` that is not the drive of a path.

An empty command, or a command or argument with a NUL byte, gives `error("process: command must be nonempty and arguments cannot contain NUL")`.

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

Waits for the program to end, and gives its exit code. A timeout leaves the program running.

Output that the program wrote, and you have not read, stays readable after `wait`.

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

For a program from `Process.spawn`, the task that closes it waits for the program to end, for one second at most. Other tasks keep running meanwhile.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn("sleep", ["10"], 1000).unwrap!
  Process.close(p)
  puts("stopped")
end
```

The program's standard error goes straight to your program's standard error, unless you start it with `Process.spawn_captured`.

## Process.spawn_captured

```text
Process.spawn_captured(command: String, args: List[String], dir: String, timeout_ms: Int) -> Result[Process]
```

Starts a program in the folder `dir` (`"."` is the current folder), and keeps its output.

- Standard output and standard error are read all the time, into buffers of 1 MiB each. So the program never blocks on a full pipe, and its standard error is never printed.
- `Process.read_line` and `Process.read_bytes` read standard output as usual.
- The command is found as for `Process.spawn`, from the current folder, not from `dir`.
- When more than 1 MiB of standard output is waiting, or standard error passes 1 MiB, the rest is dropped. Every read of standard output then gives `error("process: output exceeds 1048576 bytes")`.
- `Process.read_bytes(p, 0, timeout)` gives that error at once, so you can check for it without waiting.

Closing a captured program:

- It asks the program to stop with `SIGTERM`, and kills it one second later if it still runs. So a program that is itself an Agentica program can stop its own children.
- Windows has no `SIGTERM`. The program ends at once.
- On Windows, where libuv can assign its job object, the programs the VM started die when the VM ends. A program that is itself an Agentica program stops its own children the same way. Other descendants are not covered.

`agentica test` runs each [BDD](/library/testing/bdd/) scenario, and each program under test, as a captured program.

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

Waits until a captured program has closed its standard output and standard error. Then it gives `ProcessOutput(stdout: String, stderr: String, truncated: Bool)`:

- `stdout`: the standard output you have not read yet.
- `stderr`: all of standard error.
- `truncated`: whether some output was dropped.

It reads nothing away, so you can call it again. A program from `Process.spawn` gives `error("process: output is not captured")`.

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

Starts a program like `Process.spawn_captured`, and also opens a private channel to it, apart from its standard input, output and error. The channel carries lines of text in both directions. It works on Linux, macOS and Windows, `agentica test` included.

- On Unix (Linux and macOS), the channel is a socket pair. The program finds it on file descriptor 3, and its environment holds `AGENTICA_CHANNEL=3`.
- On Windows, the channel is a pipe in each direction. The program reads descriptor 3 and writes descriptor 4. The variable is `AGENTICA_CHANNEL=3,4`.
- `Process.spawn` and `Process.spawn_captured` remove that variable from the environment they pass on. So a program sees only a channel that its own parent opened for it.
- A program that talks to its parent on a channel keeps its own standard input and output. `agentica test` uses such a channel for the unit test files and BDD scenarios it runs.

## Process.channel_read_line, Process.channel_send and Process.channel_close

```text
Process.channel_read_line(p: Process, timeout_ms: Int) -> Result[String]
Process.channel_send(p: Process, text: String, timeout_ms: Int) -> Result[Void]
Process.channel_close(p: Process, timeout_ms: Int) -> Result[Void]
```

- `channel_read_line` reads one line the program sent, as `Process.read_line` does. A line is at most 1 MiB, and the line ending is removed. When the channel has ended, it gives `error("process: end of input")`.
- `channel_send` sends at most 1048576 bytes, exactly as given. Add your own `"\n"`.
- `channel_close` closes only the sending side. The program reads the end of its input, and you can still read what it sends.
- Closing twice is fine, and so is closing after the program has exited.
- If the program's standard output or error is cut (see `Process.read_available`), a `channel_read_line` with no complete line gives `error("process: output exceeds 1048576 bytes")` at once. So a program that prints forever is noticed without waiting for the timeout.
- A timeout in `channel_read_line` or `channel_send` closes the channel, and only the channel. The program keeps running. Later channel calls give `error("process: channel is closed")`.
- On a program started without a channel, all three give `error("process: the child has no channel")`.

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

Gives the standard output of a captured program that has arrived since the last call, and removes it.

- It never waits for more output. The timeout only bounds the wait for the read lock.
- One call takes at most about 2 MiB. Call it again for the rest.
- If the arrived bytes end in the middle of a UTF-8 character, the incomplete bytes wait for the next call. A character is never split, unless the output has ended.
- Output that the program wrote to standard output before it wrote a line on the channel is in the text once you have read that line. So a program that flushes its output before it sends a record ties that output to the record.
- After the output was truncated, it gives `error("process: output exceeds 1048576 bytes")`.
- On a program from `Process.spawn`, it gives `error("process: output is not captured")`.

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

The program's side of the channel that its parent opened with `Process.spawn_channel`. The rules are those of `channel_read_line` and `channel_send`. The timeout must be positive, and a timeout closes the channel for good.

- A program that was not given a channel gets `error("process: no parent channel")`.
- The VM takes the channel at start-up, only when `AGENTICA_CHANNEL` has the system's value (`3`, or `3,4` on Windows). On Unix, descriptor 3 must be a socket, or a FIFO opened for reading and writing. On Windows, descriptor 3 must be a readable pipe and descriptor 4 a writable one.
- A regular file, a device or a one-way FIFO on descriptor 3 is left alone. The program then has no channel.
- The VM hides the descriptors and removes the variable, so the program's own children do not inherit them.

These two calls are for runner code such as `agentica test`. A test or step that calls them can break the protocol between the runner and its file. Nothing stops it.

```agentica {mode="check"}
def main() -> Void
  line = Process.parent_read_line(5000)
  if line.ok?
    sent = Process.parent_send("echo " + line.unwrap! + "\n", 5000)
  end
end
```
