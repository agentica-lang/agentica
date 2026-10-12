# Processes

Process is an opaque handle with no constructor, fields, equality, or JSON encoding. IO.inspect prints `<Process>`.

~~~text
Process.spawn(command: String, args: List[String], timeout_ms: Int) -> Result[Process]
Process.send(p: Process, text: String, timeout_ms: Int) -> Result[Void]
Process.send_bytes(p: Process, bytes: List[Int], timeout_ms: Int) -> Result[Void]
Process.read_line(p: Process, timeout_ms: Int) -> Result[String]
Process.read_bytes(p: Process, count: Int, timeout_ms: Int) -> Result[List[Int]]
Process.close_stdin(p: Process, timeout_ms: Int) -> Result[Void]
Process.wait(p: Process, timeout_ms: Int) -> Result[Int]
Process.close(p: Process) -> Void
~~~

- Launching requires agentica --allow-run file.agc. The flag defaults off and precedes the source file; later arguments reach System.args. The test command accepts it before or after the command. Checking and builtin help need no flag. Permission reaches tasks, HTTP callbacks, BDD handlers, and programs started by BDD. The existing BDD runner can still launch its programs without granting them Process.spawn.
- A bare name (no `/`) is looked up in each `PATH` entry in order, never in the working directory: run a program in the current directory as `./name`. A command with `/` is a path, relative to the inherited working directory unless absolute. Not found, or a directory, is "executable is unavailable". On Windows the evaluator also searches the current directory before `PATH`. Children inherit the environment. Arguments are passed directly without shell interpolation. Empty commands, NUL-containing arguments, and unavailable executables fail. On Windows only `.exe` and `.com` programs run; other files, such as batch files, fail. A file that is found but cannot be executed is an error Result from `spawn` on the VM; on the evaluator, spawn succeeds and the child writes the failure to stderr and exits nonzero, so check both.
- On the VM (`agentica --vm --allow-run file.agc`, Linux) every `Process` function runs; the VM takes `--allow-run` itself. A signal (`SIGINT`, `SIGTERM`, `SIGHUP`) to the VM kills its running children before it ends.
- Timeouts are positive milliseconds, including lock wait. Read and write locks are independent. A timeout after starting stream I/O kills and closes the child; timing out while waiting for its lock preserves it. Waiting for exit times out without terminating the child.
- Sends accept at most 1048576 UTF-8 bytes or integers 0..255 and flush before succeeding. Invalid data consumes nothing. read_bytes accepts 0..1048576 and waits for that count or EOF: short/empty EOF succeeds, and zero consumes nothing.
- read_line consumes a line of at most 1 MiB, strips LF/CRLF, and strictly decodes UTF-8. An unterminated final line succeeds; empty EOF is an error. Invalid UTF-8 consumes the completed line. An oversized line closes the child.
- close_stdin flushes and closes input idempotently; further sends fail. wait returns the host exit code, including nonzero codes, and can be repeated. It preserves unread stdout and waits for stderr forwarding to finish.
- Stderr streams separately to the evaluation's error port with a fixed-size buffer. Output has no lifetime cap. A child can block when stdout's pipe fills: use Task to read concurrently with sending or waiting.
- Handles belong to their evaluation. close force-kills a running child, reaps it, closes owned ports/workers, and is idempotent. Other operations on closed handles fail. Main return, System.exit, diagnostics, task failures, step exhaustion, and external interruption also clean up directly spawned children. Arbitrary descendant trees are outside the cleanup guarantee. Borrowed ports remain open.
- Operational failures return String error Results. Cross-evaluation access is RUNTIME-PROCESS-CONTEXT; explicit cleanup failures are RUNTIME-PROCESS-CLOSE, at the call span.
