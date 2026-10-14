### 10.4 Processes

- `--allow-run` is the VM's own flag, checked inside `Process.spawn` at call time, for every task and handler.
- The VM resolves the executable itself, with the rule of the grammar (Processes): a command with `/` resolves against the program's working directory, and a bare name is looked up in each `PATH` entry in order. Empty entries are skipped, and an explicit relative entry such as `.` resolves against the working directory. The VM never adds the working directory itself. It passes the absolute path to `uv_spawn`. All three stdio streams are pipes. `UV_PROCESS_WINDOWS_VERBATIM_ARGUMENTS` is never used.
- A child must not get `UV_USE_IO_URING=0` from the VM's own environment (§10.2.2), unless the user set it before the VM started.
- Windows (not built): allow only `.exe` and `.com` after resolution, case-insensitively, and reject names with a trailing dot or space or any `:`. The allowlist applies to the last component of the resolved path. The port must not search the current directory before `PATH`.

**As built (processes PR, Linux).** `vm/process.c` holds the eight `Process` builtins. Other systems get none.

- **Values.** A `Process` has a registered state and two lock records, `reader` and `writer`. `read_line` and `read_bytes` take the reader lock. `send`, `send_bytes` and `close_stdin` take the writer lock. `wait` and `close` take neither. A reader parked on a silent child never blocks a writer, and a lock-wait timeout leaves the process running.
- **Spawn.** Checks, in order: `--allow-run`; a nonempty command with no NUL; the timeout. A path that does not exist, or is a directory, gives `process: executable is unavailable`. The pipes are real pipes, not socketpairs. The first spawn marks every inherited descriptor above 2 close-on-exec, so a child sees only 0, 1 and 2. A failed `uv_spawn` (`EACCES`, `ENOEXEC`) is an error `Result` with the OS text.
- **Parking.** Operations park only their task, with the call's timeout. Stdout is read only while a reader waits, 4 KiB at a time (more when `read_bytes` needs more), so the VM reads at most about 4 KiB past what the program asked. A child that writes more than the program reads blocks on its pipe. A read error after a partial line returns the error, not the partial line. `wait` returns when the child has exited and its stderr is at EOF. A timed-out read or write closes the process. A timed-out `wait` leaves the child running.
- **Stderr** is read all the time, and each chunk goes to the program's stderr at once, so it keeps its order with `IO.warn`. If that write fails (`/dev/full`, say), the rest is read and dropped, and the child is kept.
- **Close.** `Process.close`, a timed-out read or write, the end of the run (step 1 of §14.4) and a stop signal share one close. A running child gets `SIGKILL`, and `waitpid` is polled with `WNOHANG` for at most 1 second. A cleanup of all children kills them first and then reaps them under one shared 1-second deadline, inside the driver's 2-second grace (`docs/vm/08-loader-and-cli.md` §9). A child that cannot be killed (uninterruptible sleep, or `EPERM` after `sudo`) is not waited for: libuv reaps it later. A failed kill in `Process.close` ends the run with `RUNTIME-PROCESS-CLOSE`. Inside a timed-out read or write, the timeout error stands. If a child is still there at the end of the run, the VM ends with `_exit` and `init` gets the child. Otherwise the pipes close at once, and the waiting reader, writer and waits see `process: process is closed`. A second `close` does nothing, and any later operation returns `process: process is closed`. No child outlives a run that ends normally.
- **Signals.** A stop signal takes the one exit path (§10.2.2): children are killed and reaped, files are flushed, and the signal is raised again. Children are killed before the file flush. A VM killed by `SIGKILL`, or ended by the out-of-memory exit (70, §6.3), leaves its children running. On a break, `agentica` waits 2 seconds, sends `SIGTERM`, and kills the VM 2 seconds later (`docs/vm/08-loader-and-cli.md`).
- **Behavior notes.**
  - A file that exists but cannot be executed (no execute permission, a bad format) is an error `Result` from `Process.spawn`.
  - A `read_line` or `read_bytes` pending in another task when the process is closed returns `process: process is closed`.
  - libuv resets signals 1 to 31 to their default in the child, so a signal the VM inherited as ignored (`nohup`) is not ignored in its children. The VM does not patch libuv.
  - `Process.spawn` checks its timeout but does not apply it to the lookup and start.

**As built (21a, captured processes, Linux).** `Process.spawn_captured` and `Process.output` (specified in `docs/grammar/06d-io-and-network.md`) share the code above.

- **Spawn.** The checks keep the order above, with `dir` (nonempty, no NUL) checked after the arguments and before the timeout. `dir` must be a directory, else `process: directory is unavailable`. `"."` passes no working directory.
- **Reading.** Both pipes are read from the spawn on and never stopped. Pending bytes are capped at 1 MiB. A byte that does not fit marks its stream as cut, and later chunks of that stream are read and dropped, so the child never blocks. The stdout limit counts unread bytes. Stderr keeps its first 1 MiB.
- **Output.** `Process.output` is a wait that is ready when stdout is at EOF or has a read error, and stderr is at EOF. The record is built from the pending bytes, with U+FFFD for invalid UTF-8, and nothing is consumed. It charges a turn cost by the bytes it copies.
- **Close.** `shut` sends `SIGTERM` to a running captured child and starts a 1-second grace timer. The pipes close, and the program sees `process: process is closed` at once. When the timer fires, `SIGKILL` is sent, and libuv reaps the child, so `Process.close` never blocks. At the end of the run and on a stop signal, plain children get `SIGKILL`, captured ones get `SIGTERM` (if not sent yet), the captured ones are polled under one 1-second deadline, and the rest get `SIGKILL` and are reaped under another 1-second deadline. A child that handles `SIGTERM` ends the cleanup in milliseconds. A failed `SIGTERM` in `Process.close` is `RUNTIME-PROCESS-CLOSE`.

### 10.5 Limits the C runtime keeps

| Limit | Value |
|---|---|
| `IO.read_bytes` count | 0..1 MiB |
| Process send, read, line | 1 MiB |
| File read, line, text, writes | 1 MiB |
| TCP `send_bytes`, `recv_bytes`, line (`TCP.send` of a String has no limit, as in the grammar) | 1 MiB |
| Byte values | 0..255 |
| `List.repeat` count | 0..1048576 |
| HTTP start and header line | 8192 bytes |
| HTTP header block | 65536 bytes |
| HTTP headers | 100 |
| HTTP interim responses | 15 accepted, the 16th fails |
| `max_connections` | at most 65536 |
| HTTP body | `max_body_bytes`, 413. The body is held whole, so the default is 1 MiB and the cap 64 MiB (10.7) |
| Process launch | `--allow-run` |
| Windows programs other than `.exe`, `.com` | rejected |

HTTP numbers: `Content-Length` and chunk sizes accumulate with saturation. Parsing stops once a value exceeds the limit (413), and every comparison is written `size > limit - total`.
