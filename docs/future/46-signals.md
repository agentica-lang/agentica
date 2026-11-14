## 46. Signals

Issue #991 (one issue per phase). 46a (subscribing, `System.subscribe`, #1477)
is built: `site/content/library/io-and-system/system.md` and
`docs/vm/10-io-scheduler.md` §10.2.2. 46d (the graceful HTTP stop,
`HTTP.shutdown`, #1479) is built:
`site/content/library/io-and-system/network.md` and `docs/vm/10-io-http.md`.
This file keeps the design of 46b. Linux first.

The owner asked for a way to catch the OS stop signal in an Agentica program. A
container entrypoint should stop its child, run cleanup and exit with the right
code. The reference is a launcher script that registers and runs a GitHub
Actions self-hosted runner.

### 46.1 Today

A program receives a signal as a value (`System.subscribe`, 46a), but it can
send none: the VM signals only the children it started, by pid, at a stop
(descendants are reached only with `pgroup`). A grandchild re-parented to a VM
running as PID 1 stays a zombie (`docker run --init` avoids this).

### 46.2 Goals

1. **The entrypoint, end to end.** A program starts a child, catches TERM or
   INT, stops the child, waits for it with a deadline and kills the child's
   group if it is late, runs cleanup (which may spawn a process or make an HTTP
   call), and exits with the right code.
2. **A graceful HTTP server stop.** Stop accepting, and let the requests in
   flight finish within a deadline: `HTTP.shutdown` (46d, built).
3. **A CLI that cleans temp files on Ctrl-C:** subscribe to INT, clean up, exit
   130.
4. **No program code in a C signal handler.** The handler only records the
   signal; the program sees a signal as a value on a channel.

Non-goals: reloading state on SIGHUP (delivery only), Windows, and signals to
processes of another user (the OS decides).

### 46.3 Design

A signal is a value that a task receives, as in the task and channel model. No
callbacks. Receiving is built (46a); the enum is `System.Signal`.

#### 46.3.4 Sending, groups and other pids

```text
Process.signal(process: Process, signal: System.Signal) -> Result[Void]
Process.spawn_group(command: String, args: List[String], dir: String, timeout_ms: Int) -> Result[Process]
Process.signal_group(process: Process, signal: System.Signal) -> Result[Void]
System.signal(pid: Int, signal: System.Signal, comm: String) -> Result[Void]
```

- `Process.signal` signals the child's pid (an exited or closed child is an
  error `Result`); `Process.wait` does not change.
- `spawn_group` starts the child in a new session (`setsid`), so its pid is the
  group id. The child inherits the VM's stdin, stdout and stderr, as Python's
  `Popen` does with no arguments: no pipe, nothing can stall, and its output
  goes to the container's logs. The program cannot read that output
  (`Process.read_line`, `output` and the channel calls give an error `Result`),
  and the child shares stdin with the program. A pump task copying a pipe was
  rejected: it must always run, so it is more machinery for the same result.
  `Process.wait` returns when the leader exits. The command resolves against
  the program's working directory, not `dir`, so a program uses an absolute
  path.
- `signal_group` is `kill(-pid, sig)`. It is an error for a child not made by
  `spawn_group`, and once the leader has been reaped (while the leader exists
  its pid cannot be reused, so the group id is safe).
- `Process.close` and the end of the run send SIGKILL to the whole group of a
  `spawn_group` child (no SIGTERM step: its streams are never captured).
- `System.signal(pid, signal, comm)` reaches a process that is not a child, such as
  the runner's listener (a grandchild found by scanning `/proc/*/comm`).
  Signalling the run.sh group was rejected (it also reaches the job worker), and
  a check-less `System.signal(pid, signal)` was rejected (pid reuse). The VM opens
  a pidfd with `pidfd_open`, reads `/proc/<pid>/comm`, compares it with `comm`
  (the kernel's 15-byte form; `Runner.Listener` is exactly 15), and sends the
  signal with `pidfd_send_signal` on that same pidfd, so it can only reach the
  process the pidfd names; if it has exited and been reaped the call fails with
  ESRCH. A pid of zero or less, and the VM's own pid, are errors; the kernel
  checks the user.
- Kernel and libc: `pidfd_open` needs Linux 5.3 and `pidfd_send_signal` 5.1; the
  release builds against glibc 2.28, which has no wrappers, so the VM calls
  `syscall()` with hand-defined numbers and probes once at the first call (by
  opening a pidfd for its own pid). ENOSYS and EPERM (a seccomp filter) mean
  unavailable: `error("signal: pidfd is unavailable")`. Not `kill()` after the
  name check: the window can signal a stranger.

**Permissions:** `--deny-run` turns off `spawn_group` and `System.signal` (a pid
signal reaches any process of the same user, the class `--deny-run` covers);
`Process.signal` and `signal_group` need nothing more. No `--deny-signal`.

**Platforms:** Linux first, on the glibc 2.28 baseline. `System.Signal.Kill` is
a value to send, never one to receive; SIGSTOP is not in the enum.
`spawn_group`, `signal_group` and `System.signal` need Linux (process groups
and pidfd).
Windows would map Ctrl-C and Ctrl-Break to INT and TERM later and would need a
job object for groups; not designed here.

**Children and tests:** a driven VM sets `PR_SET_PDEATHSIG` to SIGTERM, and
`agentica test` stops each scenario's VM with `Process.close` (SIGTERM, then
SIGKILL one second later), so a test program that subscribes to TERM and needs
more than a second to clean up is killed by the runner.

**Layers:** `Process.signal`, `signal_group`, `spawn_group` and
`System.signal` go in `vm/process.c`, a service (`docs/vm/15-layers.md`).

### 46.4 The entrypoint in Agentica

How the gh-runner launcher maps: `handle_signal` becomes a task that reads the
first value of `System.subscribe([System.Signal.Term, System.Signal.Int])`
(later values stay queued and unread: the "ignore later signals" rule); the
1-second poll of `Popen.wait` becomes `Task.await(finished, 1000)` with
`Await.TimedOut` as the tick; `start_new_session=True` becomes
`Process.spawn_group`, `os.killpg` becomes `Process.signal_group`, and `os.kill`
on each listener becomes `System.signal(pid, signal, comm)`. The program subscribes
before the child starts, for the whole run. A signal before the subscription
takes the default path.

### 46.5 Phases

- **46b: sending.** `Process.signal`, `spawn_group`, `signal_group` and
  `System.signal`, with the pidfd probe and `--deny-run`; the group close and
  the end-of-run group kill.
