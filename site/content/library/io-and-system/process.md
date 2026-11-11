---
title: Process
weight: 3
description: Start other programs, talk to them through their input and output, and wait for them.
---

A `Process` is an opaque handle, with no constructor, fields, equality or JSON encoding; `IO.inspect` prints `<Process>`. A program can start other programs unless it runs with `--deny-run` (or `--sandbox`, or `agentica run --deny-run`). Then every start returns an error that begins with `denied: --deny-run`, in every task, and extern blocks are refused as with `--deny-native`. The flag goes before the source file; later arguments reach `System.args`. Under `agentica test`, a step program cannot start a program under test:

```sh
agentica --deny-run tool.agc
```

- Timeouts are positive milliseconds and include the wait for the handle's lock. A timeout during stream I/O kills and closes the program; a timeout while waiting for the lock keeps it; a timed-out wait for exit does not terminate it.
- Arguments go to the program as they are. No shell is involved. Every waiting function takes a timeout in milliseconds; the spawn functions take theirs in [Process.Options](#processoptions), 30000 by default.
- A program you start belongs to the task that started it and stops when that task ends, however it ends. Programs still running stop when yours ends. [Task.spawn_owning](/library/concurrency/task/#taskspawn_owning) gives one to a new task.

## Process.Options

```signature
Process.Options(timeout_ms: Int = 30000, chdir: String = ".", env: Map[String, String] = {}, out: String = "", err: String = "", pgroup: Bool = false)
```

The options of `Process.spawn`, `Process.spawn_captured` and `Process.spawn_channel`, their last argument, which defaults to `Process.Options()`. Give only the fields you need: `Process.Options(chdir: "build", err: "err.txt")`. The fields are Ruby's `spawn` options (`chdir:`, `out:`, `err:`, `pgroup:`), plus `timeout_ms` and `env` (Ruby passes the environment as the first argument). A timeout or a folder in the place of the options is `CHECK-TYPE-MISMATCH`.

## Process.spawn

```signature
Process.spawn(command: String, args: List[String], options: Process.Options = Process.Options()) -> Result[Process]
```

Starts a program with your program's environment, plus the variables of `env`.

- The program starts in the folder `chdir` (`"."`, the default, is the current one). An empty `chdir` or one with a NUL byte gives `error("process: chdir must be nonempty and cannot contain NUL")`, and one that is not a folder `error("process: directory is unavailable")`. The command is found from the current folder, not from `chdir`.
- A name with no `/` (`"echo"`) is looked up in each `PATH` folder, in order. The current folder is never added and empty entries are skipped; a relative entry such as `bin` is looked up under the current folder, as in the shell.
- A command with `/` is a path (on Windows `\` and a drive such as `C:` too), relative to the current folder: run a local program as `"./tool"`.
- `env` sets variables for that program only, on top of a copy of your environment: a pair replaces the variable of the same name (Windows ignores case, also of letters like `Ä`, and a map with two names that differ only in case is an `error`), and an empty value is a value. Your own environment does not change, and a `PATH` in `env` does not change how the command is found: your `PATH` resolves it, and only the program sees the new one. An empty name, a name with `=`, or a NUL byte in a name or value is an `error`, and so are `AGENTICA_CHANNEL`, `AGENTICA_VM_METRICS`, `AGENTICA_VM_METRICS_FILE` and `UV_USE_IO_URING`, which the VM owns.
- A name not found, or one that names a directory, gives `error("process: executable is unavailable")`. A file that cannot run (no execute permission) is an error from `spawn`.
- An empty command, or a NUL byte in the command or an argument, gives `error("process: command must be nonempty and arguments cannot contain NUL")`.
- `out` and `err`, when not empty, are files that get the program's standard output and error, with no shell and without the 1 MiB limit of a read or a captured stream (Ruby's `spawn(cmd, out: path)`). Each is created or truncated, on Unix with mode 0666 less where the umask clears bits, as `File.write_text` and a shell's `>` make it; a file that exists keeps its mode. A relative path starts at the current folder. `out` and `err` naming one file share it, as `> file 2>&1` does. A stream sent to a file is not readable: `read_line` gives the end of output at once, and nothing is forwarded to your standard error. A folder, the descriptor behind your standard output or error (`/proc/self/fd/5`), one of the program's own internal pipes, or on Windows a path starting `\\.\` or `\\?\` gives `error("process: out does not refer to a regular file")` (or `err`), as the `File` calls refuse them. A file that cannot be opened (a missing parent folder, no permission) gives an error that starts with `process: cannot open the out file` (or `err`) and names the system error. Either way no program starts. A NUL byte gives `error("process: out and err cannot contain NUL")`, and `--deny-fs` turns them off. The files are opened just before the start, so a start that then fails (a file that cannot run) may leave them created or truncated, as a shell's `>` does. Only `Process.spawn` takes them: `spawn_captured` and `spawn_channel` give `error("process: out and err need Process.spawn")`.
- `pgroup: true` (also for `spawn_captured` and `spawn_channel`) starts the program in its own process group, as a new session on Linux and macOS. Unlike Ruby's `pgroup: true`, the new session leaves the program with no controlling terminal, so a prompt on `/dev/tty` fails. As for any group of its own, a Ctrl-C or hangup of the terminal reaches it only through your program's stop of its children, and a `SIGKILL` of your program leaves the group running. A stop of the program while it runs (`close`, a stream timeout, the end of the run, a signal to your program) signals the whole group, so the programs it started end with it: a compiler driver and its `cc1`, or `sh` and its `sleep`. After a `SIGTERM` the group gets `SIGKILL` when the grace ends, even if the program itself has already exited. A descendant left behind by a program that exited on its own, before any stop, is not stopped. A program started without `pgroup` is stopped alone, and its own children can outlive it. On Windows `pgroup` changes nothing: the program is stopped alone.
- Windows: only `.exe` and `.com` run (`PATHEXT` is not read; a suffixless name tries `.exe` first; use `cmd.exe` by name for a shell). These fail: a name ending in a dot, a space, `.cmd` or `.bat`; one starting with `\\?\` or `\\.\`; a `:` that is not a drive.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn("echo", ["hello"]).unwrap!
  puts(Process.read_line(p, 1000))
  puts(Process.wait(p, 1000))
end
```

```text
ok("hello")
ok(0)
```

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn("sh", ["-c", "echo $GREETING"], Process.Options(env: {"GREETING": "hello"})).unwrap!
  puts(Process.read_line(p, 1000))
end
```

```text
ok("hello")
```

```agentica {mode="check"}
def main() -> Void
  options = Process.Options(out: "out.txt", err: "err.txt")
  p = Process.spawn("sh", ["-c", "echo report; echo warning >&2"], options).unwrap!
  puts(Process.wait(p, 1000))
  puts(File.read_text("out.txt"))
end
```

```text
ok(0)
ok("report\n")
```

## Process.send and Process.send_bytes

```signature
Process.send(p: Process, text: String, timeout_ms: Int) -> Result[Void]
Process.send_bytes(p: Process, bytes: Bytes, timeout_ms: Int) -> Result[Void]
```

Write to the program's standard input, and flush. A send takes at most 1048576 bytes, UTF-8 text or a `Bytes`; invalid data consumes nothing.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn("cat", []).unwrap!
  _ = Process.send(p, "ping\n", 1000)
  puts(Process.read_line(p, 1000))
  Process.close(p)
end
```

```text
ok("ping")
```

## Process.read_line and Process.read_bytes

```signature
Process.read_line(p: Process, timeout_ms: Int) -> Result[String]
Process.read_bytes(p: Process, count: Int, timeout_ms: Int) -> Result[Bytes]
```

Read from the program's standard output.

- `read_line` removes the line ending (LF or CRLF), takes at most 1 MiB and decodes strictly. At the end of output it gives an error, and a line over 1 MiB closes the program.
- `read_bytes` takes `count` from 0 to 1048576, waits for that many bytes or the end of output, and gives them as [`Bytes`](/library/data-structures/bytes/). At the end of output they are empty.

## Process.close_stdin

```signature
Process.close_stdin(p: Process, timeout_ms: Int) -> Result[Void]
```

Closes the program's input, so it sees the end of input. It flushes first, and closing twice is fine.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn("wc", ["-l"]).unwrap!
  _ = Process.send(p, "a\nb\n", 1000)
  _ = Process.close_stdin(p, 1000)
  puts(Process.read_line(p, 1000).unwrap!.strip)
end
```

```text
2
```

## Process.wait

```signature
Process.wait(p: Process, timeout_ms: Int) -> Result[Int]
```

Gives the exit code, nonzero codes included (`false` gives `ok(1)`), and can be repeated. A timeout leaves the program running. Unread output stays readable after `wait`. A program blocks when its standard output pipe is full, so read it in a task while you send or wait.

## Process.close

```signature
Process.close(p: Process) -> Void
```

Stops the program if it still runs and frees it. Closing twice is fine. A running program is killed, the call waits for it to exit (other tasks run meanwhile) and closes the ports it owns; a timeout closes the program too, but does not wait for it. A failed explicit cleanup is `RUNTIME-PROCESS-CLOSE` at the call.

Return from `main`, `System.exit`, a diagnostic, a task failure, step exhaustion and an external interruption clean up the programs started directly; their descendants are covered only with `pgroup`, while the program runs. On Windows a stop is always immediate (no `SIGTERM` grace). Where libuv can assign its job object, the direct children of the VM die when the VM ends, and a child that is itself an Agentica program stops its own children the same way.

For a `Process.spawn` program, the closing task waits up to one second for it to end; other tasks keep running.

Its standard error goes to yours, unless started with `Process.spawn_captured` or an `err` file. It goes through your program's stderr buffer: while nobody reads your stderr, the child and `Process.wait` on it wait, and other tasks keep running.

## Process.spawn_captured

```signature
Process.spawn_captured(command: String, args: List[String], options: Process.Options = Process.Options()) -> Result[Process]
```

Starts a program as `Process.spawn` does, in the folder `chdir`, and keeps its output.

- Standard output and error are read all the time into buffers of 1 MiB each, so the program never blocks on a full pipe and its standard error is never printed. `read_line` and `read_bytes` read standard output as usual.
- Past 1 MiB of waiting standard output, or of standard error, the rest is dropped and every read of standard output gives `error("process: output exceeds 1048576 bytes")`. `Process.read_bytes(p, 0, timeout)` gives it at once, to check without waiting.
- `close` sends `SIGTERM` and kills the program one second later if it still runs, so an Agentica program can stop its own children. `close` and a timeout never wait, and at the end of a run a captured program gets about one second, while a `Process.spawn` program is killed at once. Windows has no `SIGTERM`: the program ends at once, and where libuv can assign its job object, programs the VM started die when the VM ends (other descendants are not covered).

## Process.output

```signature
Process.output(p: Process, timeout_ms: Int) -> Result[ProcessOutput]
```

Waits until a captured program has closed its standard output and error, then gives `ProcessOutput(stdout: String, stderr: String, truncated: Bool)`: `stdout` is what you have not read yet, `stderr` all of it, `truncated` says whether output was dropped (invalid UTF-8 in `stderr` becomes U+FFFD). It consumes nothing, so call it again if needed. A timeout is `error("process: operation timed out")` and keeps the program. A `Process.spawn` program gives `error("process: output is not captured")`.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn_captured("sh", ["-c", "echo one; echo two; echo oops >&2"]).unwrap!
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

```signature
Process.spawn_channel(command: String, args: List[String], options: Process.Options = Process.Options()) -> Result[Process]
```

Like `Process.spawn_captured`, and also opens a private channel to the program, apart from its standard input, output and error. It carries lines of text both ways, on Linux, macOS and Windows: a pipe each way, so the program reads descriptor 3, writes descriptor 4 and sees `AGENTICA_CHANNEL=3,4`.

`Process.spawn` and `Process.spawn_captured` remove that variable from what they pass on, so a program sees only a channel its own parent opened. Its standard input and output stay free.

## Process.channel_read_line, Process.channel_send and Process.channel_close

```signature
Process.channel_read_line(p: Process, timeout_ms: Int) -> Result[String]
Process.channel_send(p: Process, text: String, timeout_ms: Int) -> Result[Void]
Process.channel_close(p: Process, timeout_ms: Int) -> Result[Void]
```

- `channel_read_line` reads one line (at most 1 MiB, ending removed), as `Process.read_line` does. At the end it gives `error("process: end of input")`; a last line that the program's exit cut off, with no line ending, is not returned as a line: it gives `error("process: line cut off")`. If standard output or error was cut (see `Process.read_available`) and no complete line is there, it gives `error("process: output exceeds 1048576 bytes")` at once, so a program that prints forever is noticed without the timeout.
- `channel_send` sends at most 1048576 bytes exactly as given: add your own `"\n"`.
- `channel_close` closes only the sending side: the program reads end of input, and you can still read what it sends. Closing twice, or after exit, is fine.
- A timeout in `channel_read_line` or `channel_send` closes the channel, not the program. Later calls give `error("process: channel is closed")`.
- Without a channel all three give `error("process: the child has no channel")`.

```agentica {mode="check"}
def main() -> Void
  script = "read line <&3; echo \"got $line\" >&4"
  p = Process.spawn_channel("sh", ["-c", script]).unwrap!
  _ = Process.channel_send(p, "hello\n", 1000)
  puts(Process.channel_read_line(p, 1000))
  Process.close(p)
end
```

```text
ok("got hello")
```

## Process.read_available

```signature
Process.read_available(p: Process, timeout_ms: Int) -> Result[String]
```

Gives, and removes, the standard output of a captured program that has arrived since the last call.

- It never waits for more output; the timeout only bounds the wait for the read lock. One call takes at most about 2 MiB.
- Bytes that end mid-character wait for the next call, so a character is never split (unless the output has ended).
- Output written before a channel line is in the text once you have read that line, so flushing before sending a record ties the output to the record.
- After truncation it gives `error("process: output exceeds 1048576 bytes")`. On a `Process.spawn` program, `error("process: output is not captured")`.

```agentica {mode="check"}
def main() -> Void
  script = "echo working; echo done >&4"
  p = Process.spawn_channel("sh", ["-c", script]).unwrap!
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

```signature
Process.parent_read_line(timeout_ms: Int) -> Result[String]
Process.parent_send(text: String, timeout_ms: Int) -> Result[Void]
```

The program's side of the channel its parent opened with `Process.spawn_channel`, with the rules of `channel_read_line` and `channel_send`. The timeout must be positive, and a timeout closes the channel for good. Without a channel: `error("process: no parent channel")`.

- The VM takes the channel at start-up only when `AGENTICA_CHANNEL` is `3,4` and descriptor 3 is open for reading and 4 for writing, each a pipe, a FIFO or a socket (on Windows a pipe). On Linux and macOS it also takes `3` with one socket or FIFO open both ways on descriptor 3, the form of earlier versions. Anything else (a regular file, a device, a pipe the wrong way round) is left alone: no channel.
- The program's own children do not inherit the descriptors or the variable.

These calls are for runner code such as `agentica test`. A test that calls them can break the protocol between the runner and its file, and nothing stops it.

```agentica {mode="check"}
def main() -> Void
  line = Process.parent_read_line(5000)
  if line.ok?
    _ = Process.parent_send("echo " + line.unwrap! + "\n", 5000)
  end
end
```
