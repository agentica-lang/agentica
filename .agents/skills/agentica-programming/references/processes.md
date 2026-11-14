# Processes

`Process` is an opaque handle with no constructor, fields, equality or JSON
encoding.

```text
Process.Options(timeout_ms: Int = 30000, chdir: String = ".", env: Map[String, String] = {},
                out: String = "", err: String = "", pgroup: Bool = false)
Process.spawn(command: String, args: List[String],
              options: Process.Options = Process.Options()) -> Result[Process]
Process.send(process: Process, text: String, timeout_ms: Int) -> Result[Void]
Process.send_bytes(process: Process, bytes: Bytes, timeout_ms: Int) -> Result[Void]
Process.read_line(process: Process, timeout_ms: Int) -> Result[String]
Process.read_bytes(process: Process, count: Int, timeout_ms: Int) -> Result[Bytes]
Process.close_stdin(process: Process, timeout_ms: Int) -> Result[Void]
Process.wait(process: Process, timeout_ms: Int) -> Result[Int]
Process.close(process: Process) -> Void
Process.spawn_captured(command: String, args: List[String],
                       options: Process.Options = Process.Options()) -> Result[Process]
Process.output(process: Process, timeout_ms: Int) -> Result[Process.Output]
Process.spawn_channel(command: String, args: List[String],
                      options: Process.Options = Process.Options()) -> Result[Process]
Process.channel_read_line(process: Process, timeout_ms: Int) -> Result[String]
Process.channel_send(process: Process, text: String, timeout_ms: Int) -> Result[Void]
Process.channel_close(process: Process, timeout_ms: Int) -> Result[Void]
Process.read_available(process: Process, timeout_ms: Int) -> Result[String]
Process.parent_read_line(timeout_ms: Int) -> Result[String]
Process.parent_send(text: String, timeout_ms: Int) -> Result[Void]
```

- The options of a start go in the builtin record `Process.Options`; give only
  the fields you need:
  `Process.spawn("make", [], Process.Options(chdir: "build"))`. A positional
  timeout or folder is `CHECK-TYPE-MISMATCH`, and four or more arguments are
  `CHECK-ARITY`.
- Launching needs no flag. With `--deny-run` (or `--sandbox`) every start
  returns an error beginning `denied: --deny-run`, and extern blocks are
  refused as with `--deny-native`. `agentica test` passes the `--deny-*` flags
  and `--sandbox` on to test files, step programs and programs under test.
- Each spawn starts the child in `chdir` (`"."` keeps the working directory;
  not a directory is "directory is unavailable"). The command still resolves
  against the program's working directory, not `chdir`.
- A bare command name (no `/`) is looked up in each `PATH` entry in order; the
  working directory is never added: run a program
  in the current directory as `./name`. A command with `/` is a path,
  relative to the inherited working directory unless absolute. Not found, or a
  directory, is "executable is unavailable". Children inherit the
  environment; `env` adds or replaces variables for that child only (an error
  for an empty name, `=` or NUL in a name, NUL in a value, or
  `AGENTICA_CHANNEL`, `AGENTICA_VM_METRICS[_FILE]`, `UV_USE_IO_URING`).
  Arguments go directly, with no shell interpolation. Empty commands, NUL in an
  argument and unavailable executables fail with an error Result.
- Windows runs only `.exe` and `.com` programs (`.bat` and `.cmd` never run:
  start `cmd.exe` by name for a shell). A command with `\`, `/` or a drive is
  a path, not searched in `PATH`. A bare name tries `.exe` before `.com`.
- A signal (`SIGINT`, `SIGTERM`, `SIGHUP`, `SIGUSR1`, `SIGUSR2`) that the
  program has not subscribed to (below), to the VM or to `agentica`, kills its
  running children, then writes open files, before it ends by that signal;
  `SIGQUIT` does the same and exits with 131. A second signal ends it at once,
  never before the children are stopped.
- Timeouts are positive milliseconds, including lock wait. Read and write locks
  are independent. A timeout after starting stream I/O kills and closes the
  child; timing out while waiting for its lock preserves it. Waiting for exit
  times out without terminating the child.
- Sends accept at most 1 MiB (UTF-8 text or a `Bytes`) and flush before
  succeeding. `read_bytes` accepts 0..1048576 and waits for that count or EOF:
  a short or empty EOF read succeeds.
- `read_line` takes a line of at most 1 MiB, strips LF/CRLF and decodes strict
  UTF-8. An unterminated final line succeeds; empty EOF is an error; an
  oversized line closes the child.
- `close_stdin` flushes and closes input, idempotently; later sends fail. `wait`
  returns the host exit code (nonzero too), can be repeated, preserves unread
  stdout and waits for stderr forwarding to finish.
- Stderr streams separately to the program's stderr. A child can block when
  stdout's pipe fills: read in a task concurrently with sending or waiting.
- `out` and `err` (not empty) send the child's stdout and stderr to files, with
  no shell and no 1 MiB limit: created or truncated (Unix mode 0666 less the
  umask; an existing file keeps its mode), relative to the working directory.
  One file for both is shared, as `> f 2>&1`. That stream is then not readable
  (`read_line` gives the end at once) or forwarded. A folder, the VM's own
  stdout/stderr descriptor name, an internal pipe or a Windows `\\.\` or
  `\\?\` path is `error("process: out does not refer to a regular file")` (or
  `err`); another failure is an error
  starting `process: cannot open the out file`; both start nothing. NUL is an
  error; `--deny-fs` refuses them. A start that fails after the open (a file
  that cannot run) may leave the files created or truncated.
- A process belongs to the task that opened it: when that task ends (return,
  crash, cancel) the child is closed as by `close`, without waiting, unless
  `Task.spawn_owning` handed it over (`tasks.md`). `close` force-kills a running
  child, waits for it to exit (other tasks run meanwhile), closes owned
  ports/workers and is idempotent; a timeout closes the child without waiting;
  other operations on a closed handle fail. The end of the run also cleans up
  directly spawned children; descendant trees are outside the guarantee
  unless the child started with `pgroup: true` (a field of `Process.Options`):
  then it leads its own process group (a new session on POSIX: no controlling
  terminal, so no `/dev/tty` prompt, and a SIGKILLed VM leaves the group) and a
  stop while it runs signals the whole group, with SIGKILL after a SIGTERM's
  grace even if the child already exited. Descendants of a child that exited on
  its own are not stopped. Windows ignores `pgroup`.
- Operational failures return String error Results; explicit cleanup failures
  are `RUNTIME-PROCESS-CLOSE`, at the call span.

## Captured processes

`spawn_captured` works like `spawn` (same lookup, `--deny-run`, environment and
cleanup) with these differences.

- `out` and `err` are an error: the streams go to the buffers below.
- The VM reads the child's stdout and stderr all the time, so the child never
  blocks on a full pipe: stdout goes into a buffer that `read_line` and
  `read_bytes` read, stderr into its own buffer and never to the program's
  stderr. Past 1 MiB of unread stdout, or of stderr, that stream is marked
  truncated and more bytes are dropped. Once either stream is truncated, every
  stdout read returns `error("process: output exceeds 1048576 bytes")`.
- `output` waits until the child's stdout and stderr both end, then returns the
  builtin record `Process.Output(stdout: String, stderr: String, truncated:
  Bool)`: the stdout not read yet, all of stderr (invalid UTF-8 becomes U+FFFD)
  and whether either stream was truncated. It consumes nothing and can repeat. A
  timeout is `error("process: operation timed out")` and keeps the child; a
  `spawn` process gives `error("process: output is not captured")`.
- Closing a captured child (`close`, a stream timeout, the end of the run) sends
  `SIGTERM`, then `SIGKILL` after one second, so a child that is an Agentica
  program can stop its own children first. `close` and a timeout never wait.
  Children from `spawn` are killed at once, and on Windows every stop is
  immediate.

## Channels

Linux, macOS and Windows. `spawn_channel` works like `spawn_captured` and
also opens a channel, separate from the child's stdin, stdout and stderr, that
carries text lines both ways: a pipe per direction. The child reads descriptor
3, writes descriptor 4, and finds `AGENTICA_CHANNEL=3,4`. `spawn` and
`spawn_captured` remove that variable from the child's environment even if your
program inherited it.

- `channel_read_line` reads like `read_line` (at most 1 MiB, LF or CRLF removed,
  strict UTF-8, `error("process: end of input")` at the end; unlike `read_line`, a
  last line cut off with no LF is `error("process: line cut off")`). `channel_send`
  sends at most 1048576 bytes as they are (add your own `"\n"`).
  `channel_close` closes only the sending side, so the child reads the end of
  its input while you can still read; it is idempotent, also after the child
  exited.
- Once stdout or stderr was cut (over 1 MiB unread), a `channel_read_line` with
  no complete line returns `error("process: output exceeds 1048576 bytes")` at
  once and leaves the channel open. A timeout in `channel_read_line` or
  `channel_send` closes the channel, not the process (later channel calls
  return `error("process: channel is closed")`). On a child from `spawn` or
  `spawn_captured` the channel calls return `error("process: the child has no
  channel")`.
- `read_available` gives the stdout captured since the last call and consumes
  it. It never waits for more output. Output the child wrote before a channel
  line is in it once you have read that line, so a child that flushes before
  it sends gets its output attributed to that record. One call takes about
  2 MiB at most. After a truncation it returns `error("process: output exceeds
  1048576 bytes")`; on a `spawn` handle `error("process: output is not
  captured")`.
- The child's side: `Process.parent_read_line(timeout_ms)` and
  `Process.parent_send(text, timeout_ms)` use the channel the parent opened,
  with the same rules and errors; with no channel they return `error("process:
  no parent channel")`. A timeout closes the channel for good. The VM takes the
  channel at startup only when `AGENTICA_CHANNEL` is `3,4` with descriptor 3
  open for reading and 4 for writing (on Linux and macOS also `3` with one
  socket or FIFO open both ways), then hides it, so your own
  children never inherit it. These calls are for runner code:
  under `agentica test`, `Test.run` and the BDD step programs use the channel
  (`testing.md`), and a test or step calling them can break the protocol.

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
- `IO.flush` flushes stdout, not stderr. A print is copied into a 64 KiB buffer
  per stream and written as the reader takes it, so output reaches a pipe
  without `IO.flush`, which can wait for a slow reader. For stdio protocols,
  write one compact JSON message per line, flush after each response and send
  logs to `IO.warn`.
- `System.env` needs no flag; `--deny-env` makes it an error starting `denied:
  --deny-env` (`System.os` and `System.pid` stay on). The home directory is
  `System.env("HOME")`. No call lists the variables.
- `System.pid` needs no flag. Pass it to a VM you start with `--driver-pid`:
  that VM checks that its parent is this process.

## Signals

```text
System.subscribe(signals: List[System.Signal]) -> Result[Channel[System.Signal]]
System.signal_number(signal: System.Signal) -> Int   # Term 15, Int 2, Hup 1, Quit 3, Kill 9
```

- `System.Signal` is `Term`, `Int`, `Hup`, `Usr1`, `Usr2`, `Quit`, `Kill`. A
  subscribed signal arrives as a value on the channel and does not stop the
  program; exit with `128 + System.signal_number(sig)` after the cleanup.
- One pending value per signal: a burst gives one value. Every subscription
  to a signal gets it. The calling task owns the channel: its end or
  `ch.close` ends the subscription, and the signal stops the program again.
- `Quit` or `Kill` in the list is `RUNTIME-INVALID-SIGNAL`; `Quit` (`Ctrl-\`)
  stays the force stop (exit 131). An empty list is an `argument` error; a
  signal ignored at start (`nohup`, `Int` in a background shell job) stays
  ignored and the rest are subscribed, and a list of only such signals is a
  `system.signal` error; Windows returns a `system.signal` error. `send` on
  the channel is an `argument` error. No flag needed, also under `--sandbox`.

```agentica
def main() -> Void
  signals = System.subscribe([System.Signal.Term, System.Signal.Int]).unwrap!
  sig = signals.recv(3600000).unwrap!
  IO.warn("stopping on #{sig}")
  System.exit(128 + System.signal_number(sig))
end
```
