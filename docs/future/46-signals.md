## 46. Signals

Issue #991 (one issue per phase). Nothing is implemented. Linux first; 46a and
46b may run before other VM work.

The owner asked for a way to catch the OS stop signal in an Agentica program. A
container entrypoint should stop its child, run cleanup and exit with the right
code. The reference is a launcher script that registers and runs a GitHub
Actions self-hosted runner.

### 46.1 Today

The VM has one stop path for SIGINT, SIGTERM and SIGHUP, and a program cannot
take part in it: no builtin reports a signal and no task sees one
(`docs/vm/14-core-invariants.md` §14.4, `docs/vm/10-io-scheduler.md` §10.2.2).
The VM signals only the children it started, by pid (descendants are not
reached). A new `uv_signal_t` watcher for the stop signals must respect
`private_pipe` in `vm/files.c` and libuv's shared signal lock. A grandchild
re-parented to a VM running as PID 1 stays a zombie
(`docker run --init` avoids this).

### 46.2 Goals

1. **The entrypoint, end to end.** A program starts a child, catches TERM or
   INT, stops the child, waits for it with a deadline and kills the child's
   group if it is late, runs cleanup (which may spawn a process or make an HTTP
   call), and exits with the right code.
2. **A graceful HTTP server stop.** Stop accepting, and let the requests in
   flight finish within a deadline. Today `HTTP.close_server` closes every
   connection and cancels the handlers. A drain is a separate change in
   `std/http` (46d).
3. **A CLI that cleans temp files on Ctrl-C:** subscribe to INT, clean up, exit
   130.
4. **No program code in a C signal handler.** The handler only records the
   signal; the program sees a signal as a value on a channel.

Non-goals: reloading state on SIGHUP (delivery only), Windows, and signals to
processes of another user (the OS decides).

### 46.3 Design

A signal is a value that a task receives, as in the task and channel model. No
callbacks.

#### 46.3.1 Subscribing

```text
Signal.channel(signals: List[Signal]) -> Result[Channel[Signal]]
Signal.number(sig: Signal) -> Int
```

`Signal` is a builtin enum with no payloads, like `TaskExit`: `Signal.Term`,
`Signal.Int`, `Signal.Hup`, `Signal.Usr1`, `Signal.Usr2`, `Signal.Quit` and
`Signal.Kill`.

- The first five can be subscribed to. `Quit` is the VM's force path (46.3.3)
  and `Kill` cannot be caught: subscribing to either is
  `RUNTIME-INVALID-SIGNAL`. An empty list is `error("signal: no signals")`; a
  duplicate is ignored.
- The channel holds one pending value per signal (capacity five). A value is
  queued only when that signal has no pending value, so nothing blocks the loop
  and counts are lost; a program that needs every press must use another
  design.
- `Signal.number(Signal.Term)` is 15 on Linux, so a program can write
  `System.exit(128 + Signal.number(Signal.Term))`.

A subscription beats a blocking `Signal.wait(names, timeout_ms)`: a wait drops a
signal that arrives before the call, and a subscription queues it from the
moment it is made.

**The name `Signal` is a risk, and the 46a PR makes the final choice** (with a
spike on the enum parameter). A user type with a builtin name is
`CHECK-REDEFINED-NAME`, so the reserved name is breaking; no builtin takes an
enum as a parameter today; and a builtin enum that shares its name with a
function namespace has no precedent (`Signal.channel(...)` would be read as a
constructor). (A) keep `Signal.channel` and `Signal.number` and make the
resolver resolve a function first; (B) move them to `System.subscribe(signals)`
and `System.signal_number(sig)` and keep `Signal` as an enum only. (B) is the
starting point (owner, 2026-10-15). The rest of this file uses the names of (A).

#### 46.3.2 Ownership and lifecycle

- The subscription belongs to the task that opened it, like any handle. It ends
  when that task ends in any way, or on `Channel.close`; queued values are still
  received, then `recv` returns `channel: closed`. `Channel.send` on it is
  `error("signal: channel is read only")`.
- A subscribed signal does not start the stop path; a signal that several
  subscriptions want goes to each of them. When the last subscription to a
  signal ends, the default action comes back, and a value still pending goes to
  the stop path then.
- A driven VM whose driver is gone does not deliver a signal: it takes the
  default path (the `PR_SET_PDEATHSIG` signal included).
- The handler keeps two atomic masks (`subscribed`, written by the loop, and
  `pending`, set by the handler, which wakes the loop with the existing
  `uv_async_send`). No `uv_signal_t` watcher: libuv restores the default action
  when it stops the last watcher of a signal.
- The stop set in `vm/loop.c` grows from INT, TERM and HUP to USR1, USR2 and
  QUIT. Without a subscription USR1 and USR2 now take the stop path (children
  stopped, output flushed) instead of ending the process at once and leaving the
  children running: a behavior change for the CHANGELOG.
- The handler has no `SA_RESTART`, so a blocking stdout or stderr write
  interrupted by a handled signal returns EINTR, which `write_failed`
  (`vm/output.c`) would report as `RUNTIME-INTERNAL`. 46a retries an EINTR write
  for the rest of its bytes.
- A signal that the VM started as ignored (`nohup`) keeps that state;
  `Signal.channel` returns `error("signal: ignored when the program started")`
  rather than override what the parent chose.

#### 46.3.3 Later signals and Quit

While a subscription exists, every Term, Int, Hup, Usr1 and Usr2 goes to the
channel, including repeats (the gh-runner ignores every signal after the first;
Go's `signal.Notify` does the same). `Quit` is never delivered: it stops the
children, flushes, and exits with `_exit(131)` without raising the signal again
(no core dump; a second Quit also exits 131). Today Quit dumps core and leaves
the children running, so it joins the stop set in 46a. A direct `agentica run`
whose program handles TERM can only be stopped by Quit (Ctrl-\) or SIGKILL, so
the site page must say so; the hard stop belongs to the parent (Docker's
SIGKILL, `Process.close`).

`STOP_GRACE_SECONDS` bounds only the default path. A handled signal never arms
it, so a program that needs ten seconds of cleanup is not cut.

#### 46.3.4 Sending, groups and other pids

```text
Process.signal(p: Process, sig: Signal) -> Result[Void]
Process.spawn_group(command: String, args: List[String], dir: String, timeout_ms: Int) -> Result[Process]
Process.signal_group(p: Process, sig: Signal) -> Result[Void]
System.signal(pid: Int, sig: Signal, comm: String) -> Result[Void]
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
- `System.signal(pid, sig, comm)` reaches a process that is not a child, such as
  the runner's listener (a grandchild found by scanning `/proc/*/comm`).
  Signalling the run.sh group was rejected (it also reaches the job worker), and
  a check-less `System.signal(pid, sig)` was rejected (pid reuse). The VM opens
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

**Permissions:** `Signal.channel` needs no flag (it only affects the program
that asks); `--deny-run` turns off `spawn_group` and `System.signal` (a pid
signal reaches any process of the same user, the class `--deny-run` covers);
`Process.signal` and `signal_group` need nothing more. No `--deny-signal`.

**Platforms:** Linux first, on the glibc 2.28 baseline. `Signal.Kill` is a value
to send, never one to receive; SIGSTOP is not in the enum. `spawn_group`,
`signal_group` and `System.signal` need Linux (process groups and pidfd).
Windows would map Ctrl-C and Ctrl-Break to INT and TERM later and would need a
job object for groups; not designed here.

**Children and tests:** a driven VM sets `PR_SET_PDEATHSIG` to SIGTERM, and
`agentica test` stops each scenario's VM with `Process.close` (SIGTERM, then
SIGKILL one second later), so a test program that subscribes to TERM and needs
more than a second to clean up is killed by the runner.

**Layers:** the stop state, the masks, the handler and the subscription table
stay in `vm/loop.c` (core); the channel offer (a send that never waits, one
value per signal) and `Signal.channel` go in `vm/channel.c`; the EINTR retry in
`vm/output.c`; `Process.signal`, `signal_group`, `spawn_group` and
`System.signal` in `vm/process.c`, a service (`docs/vm/15-layers.md`).

### 46.4 The entrypoint in Agentica

How the gh-runner launcher maps: `handle_signal` becomes a task that reads the
first value of a `Signal.channel` for `Signal.Term` and `Signal.Int` (later
values stay queued and unread: the "ignore later signals" rule); the 1-second
poll of `Popen.wait` becomes `Task.await(finished, 1000)` with `Await.TimedOut`
as the tick; `start_new_session=True` becomes `Process.spawn_group`,
`os.killpg` becomes `Process.signal_group`, and `os.kill` on each listener
becomes `System.signal(pid, sig, comm)`. The program subscribes before the child
starts, for the whole run. A signal before the subscription takes the default
path.

### 46.5 Phases

- **46a: subscription.** The `Signal` enum and its names (the PR chooses between
  (A) and (B)); the stop set grows by USR1, USR2 and QUIT; writes retry on
  EINTR; Quit takes the `_exit(131)` path. **Breaking:** `Signal` becomes a
  reserved builtin name.
- **46b: sending.** `Process.signal`, `spawn_group`, `signal_group` and
  `System.signal`, with the pidfd probe and `--deny-run`; the group close and
  the end-of-run group kill.
- **46d: graceful HTTP stop.** A drain in `std/http` (stop accepting, wait for
  the handlers up to a deadline), in Agentica, after 46b by the owner's order.
