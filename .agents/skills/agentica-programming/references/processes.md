# Processes

`Process` is an opaque handle with no constructor, fields, equality or JSON
encoding; inspect prints `<Process>`.

```text
Process.spawn(command: String, args: List[String], timeout_ms: Int = 30000) -> Result[Process]
Process.send(p: Process, text: String, timeout_ms: Int) -> Result[Void]
Process.send_bytes(p: Process, bytes: Bytes, timeout_ms: Int) -> Result[Void]
Process.read_line(p: Process, timeout_ms: Int) -> Result[String]
Process.read_bytes(p: Process, count: Int, timeout_ms: Int) -> Result[Bytes]
Process.close_stdin(p: Process, timeout_ms: Int) -> Result[Void]
Process.wait(p: Process, timeout_ms: Int) -> Result[Int]
Process.close(p: Process) -> Void
Process.spawn_captured(command: String, args: List[String], dir: String = ".", timeout_ms: Int = 30000) -> Result[Process]
Process.output(p: Process, timeout_ms: Int) -> Result[ProcessOutput]
Process.spawn_channel(command: String, args: List[String], dir: String = ".", timeout_ms: Int = 30000) -> Result[Process]
Process.channel_read_line(p: Process, timeout_ms: Int) -> Result[String]
Process.channel_send(p: Process, text: String, timeout_ms: Int) -> Result[Void]
Process.channel_close(p: Process, timeout_ms: Int) -> Result[Void]
Process.read_available(p: Process, timeout_ms: Int) -> Result[String]
Process.parent_read_line(timeout_ms: Int) -> Result[String]
Process.parent_send(text: String, timeout_ms: Int) -> Result[Void]
```

- Launching needs no flag. With `--deny-run` (or `--sandbox`) every start
  returns an error beginning `denied: --deny-run` (in every task), and extern
  blocks are refused as with `--deny-native`. `agentica test` passes the
  `--deny-*` flags and `--sandbox` on to test files, step programs and programs
  under test.
- A bare command name (no `/`) is looked up in each `PATH` entry in order; the
  working directory is never added (empty entries are skipped): run a program
  in the current directory as `./name`. A relative `PATH` entry such as `.` or
  `bin` resolves against the working directory. A command with `/` is a path,
  relative to the inherited working directory unless absolute. Not found, or a
  directory, is "executable is unavailable". Children inherit the environment.
  Arguments go directly, with no shell interpolation. Empty commands, NUL in an
  argument and unavailable executables fail; so does a found file that cannot
  be executed (an error Result from `spawn`).
- Windows runs only `.exe` and `.com` programs (`PATHEXT` is not read; `.bat`
  and `.cmd` never run: start `cmd.exe` by name for a shell). A command with
  `\`, `/` or a drive (`C:\tool\a.exe`) is a path, not searched in `PATH`; a
  name ending in a dot or space, with a `:` that is not the drive, starting with
  `\\?\` or `\\.\`, or ending in `.cmd` or `.bat`, fails. A bare name tries
  `.exe` before `.com`.
- A signal (`SIGINT`, `SIGTERM`, `SIGHUP`) to the VM or to `agentica` kills its
  running children, then writes open files, before it ends by that signal; a
  second signal ends it at once, never before the children are stopped. On
  Ctrl-C `agentica` gives the VM 2 seconds before its own `SIGTERM`. Children
  do not keep signals the VM inherited as ignored (`nohup` does not protect
  them).
- Timeouts are positive milliseconds, including lock wait. Read and write locks
  are independent. A timeout after starting stream I/O kills and closes the
  child; timing out while waiting for its lock preserves it. Waiting for exit
  times out without terminating the child.
- Sends accept at most 1048576 bytes (UTF-8 text or a `Bytes`) and flush before
  succeeding; invalid data consumes nothing. `read_bytes` accepts 0..1048576 and
  waits for that count or EOF: a short or empty EOF read succeeds, and zero
  consumes nothing.
- `read_line` takes a line of at most 1 MiB, strips LF/CRLF and decodes strict
  UTF-8. An unterminated final line succeeds; empty EOF is an error; invalid
  UTF-8 consumes the completed line; an oversized line closes the child.
- `close_stdin` flushes and closes input, idempotently; later sends fail. `wait`
  returns the host exit code (nonzero too), can be repeated, preserves unread
  stdout and waits for stderr forwarding to finish.
- Stderr streams separately to the program's stderr through a fixed buffer.
  While nobody reads the program's stderr, the child blocks on its stderr and
  `wait` does not return until it drains; other tasks keep running. A child can
  block when stdout's pipe fills: read in a task concurrently with sending or
  waiting. Output has no lifetime cap.
- A process belongs to the task that opened it: when that task ends (return,
  crash, cancel) the child is closed as by `close`, without waiting, unless
  `Task.spawn_owning` handed it over (`tasks.md`). `close` force-kills a running
  child, waits for it to exit (other tasks run meanwhile), closes owned
  ports/workers and is idempotent; a timeout closes the child without waiting;
  other operations on a closed handle fail. Main return, `System.exit`,
  diagnostics, task failures, step exhaustion and external interruption also
  clean up directly spawned children; descendant trees are outside the
  guarantee. Borrowed ports stay open.
- Operational failures return String error Results; explicit cleanup failures
  are `RUNTIME-PROCESS-CLOSE`, at the call span.

## Captured processes

`spawn_captured` works like `spawn` (same lookup, `--deny-run`, environment and
cleanup) with these differences.

- The child starts in `dir`: `"."` keeps the working directory, a relative `dir`
  resolves against it, an empty `dir` or one with NUL is an error, and one that
  is not a directory is "directory is unavailable". The command still resolves
  against the program's working directory, not `dir` (`spawn_captured("./sh",
  [], "/bin", t)` is "executable is unavailable").
- The VM reads the child's stdout and stderr all the time, so the child never
  blocks on a full pipe: stdout goes into a buffer that `read_line` and
  `read_bytes` read, stderr into its own buffer and never to the program's
  stderr. Past 1 MiB of unread stdout, or of stderr, that stream is marked
  truncated and more bytes are dropped. Once either stream is truncated, every
  stdout read returns `error("process: output exceeds 1048576 bytes")` (a read
  already waiting wakes with it; `read_bytes(p, 0, t)` returns it at once, so a
  program can check for a stderr flood without waiting).
- `output` waits until the child's stdout and stderr both end, then returns the
  builtin record `ProcessOutput(stdout: String, stderr: String, truncated:
  Bool)`: the stdout not read yet, all of stderr (invalid UTF-8 becomes U+FFFD)
  and whether either stream was truncated. It consumes nothing and can repeat. A
  timeout is `error("network: operation timed out")` and keeps the child; a
  `spawn` process gives `error("process: output is not captured")`.
  `ProcessOutput` is reserved.
- Closing a captured child (`close`, a stream timeout, the end of the run) sends
  `SIGTERM`, then `SIGKILL` after one second, so a child that is an Agentica
  program can stop its own children first. `close` and a timeout close the
  handle at once and never wait; the end of the run waits at most about a second
  for a captured child before it kills it. Children from `spawn` are killed at
  once. On Windows every stop is immediate; where libuv can assign its job
  object, the direct children die when the VM ends (an Agentica child stops its
  own children the same way); other descendants are not covered.
- `agentica test` runs each BDD scenario and each program under test as a
  captured child.

## Channels

Linux and macOS (Windows in progress). `spawn_channel` works like
`spawn_captured` and also opens a channel: a bidirectional socket pair, separate
from the child's stdin, stdout and stderr, that carries text lines both ways.
The child finds it on descriptor 3 with `AGENTICA_CHANNEL=3`. On Windows the
channel is a pipe per direction: the child reads descriptor 3, writes descriptor
4, and the variable is `AGENTICA_CHANNEL=3,4`. `spawn` and `spawn_captured`
remove that variable from the child's environment even if your program
inherited it.

- `channel_read_line` reads like `read_line` (at most 1 MiB, LF or CRLF removed,
  strict UTF-8, `error("process: end of input")` at the end). `channel_send`
  sends at most 1048576 bytes as they are (add your own `"\n"`).
  `channel_close` closes only the sending side, so the child reads the end of
  its input while you can still read; it is idempotent, also after the child
  exited.
- Once stdout or stderr was cut (over 1 MiB unread), a `channel_read_line` with
  no complete line returns `error("process: output exceeds 1048576 bytes")` at
  once and leaves the channel open. A timeout in `channel_read_line` or
  `channel_send` closes the channel, not the process: later channel calls return
  `error("process: channel is closed")`, and `read_available`, `output`, `wait`
  and `close` still work. On a child from `spawn` or `spawn_captured` the
  channel calls return `error("process: the child has no channel")`.
- `read_available` gives the stdout captured since the last call and consumes
  it. It never waits for more output (the timeout bounds only the wait for the
  read lock). Output the child wrote before a channel line is in it once you
  have read that line, so a child that flushes before it sends gets its output
  attributed to that record. One call takes about 2 MiB at most; bytes ending
  mid-UTF-8 character stay for the next call (unless the output has ended).
  After a truncation it returns `error("process: output exceeds 1048576
  bytes")`; on a `spawn` handle `error("process: output is not captured")`.
- The child's side: `Process.parent_read_line(timeout_ms)` and
  `Process.parent_send(text, timeout_ms)` use the channel the parent opened,
  with the same rules and errors; with no channel they return `error("process:
  no parent channel")`. The timeout must be positive and a timeout closes the
  channel for good. The VM takes the channel at startup only when
  `AGENTICA_CHANNEL` has the system's value (`3`; `3,4` on Windows) and
  descriptor 3 is a socket or a FIFO opened for reading and writing (a regular
  file, a device or a one-way FIFO is left alone; on Windows descriptor 3 must
  be a pipe that grants reading and 4 one that grants writing), then hides it
  and removes the variable, so your own children never inherit it. These calls
  are for runner code: under `agentica test`, `Test.run` and the BDD step
  programs use the channel (`testing.md`), and a test or step calling them can
  break the protocol.

## Standard streams and the environment

```text
IO.read_bytes(count: Int) -> Result[Bytes]       # count 0..1048576
IO.flush() -> Void                               # stdout only
System.env(name: String) -> Result[String]       # error if unset or the name is empty, has = or NUL; ok("") if set empty
System.os() -> String                            # "linux", "macos", "windows", else the lowercase uname name ("unknown" if none or not printable ASCII)
System.pid() -> Int                              # the process id of this program (VM only)
```

- `IO.read_bytes` waits for `count` bytes or end of input. A short final read
  succeeds; end of input before any byte, or a zero count, gives empty bytes.
  Invalid counts return an error without consuming input. Read larger streams in
  several calls. `String.from_bytes` decodes complete UTF-8 sequences only
  (`binary.md`).
- `IO.flush` flushes stdout, not stderr. On Linux, macOS and Windows a print is
  copied into a 64 KiB buffer per stream and written as the reader takes it, so
  output reaches a pipe without `IO.flush`; stdout and stderr to the same file
  keep the order of the calls (on Windows, when both descriptors are one handle
  object, as with a pipe given to both). `IO.flush` returns once the buffer is
  in the pipe, so it can wait for a slow reader. On other systems output does
  not auto-flush. For stdio protocols, write one compact JSON message per line,
  flush after each response and send logs to `IO.warn`.
- `System.env` needs no flag; `--deny-env` makes it an error starting `denied:
  --deny-env` (`System.os` and `System.pid` stay on). A non-UTF-8 value is
  decoded with U+FFFD for each bad byte. The home directory is
  `System.env("HOME")`. No call lists the variables. `AGENTICA_CHANNEL` and a
  `UV_USE_IO_URING` the VM set itself are hidden; a `Process.spawn` child also
  does not get `AGENTICA_VM_METRICS` or `AGENTICA_VM_METRICS_FILE`, but
  `System.env` shows them to you.
- `System.pid` needs no flag. Pass it to a VM you start with `--driver-pid`:
  that VM checks that its parent is this process.
