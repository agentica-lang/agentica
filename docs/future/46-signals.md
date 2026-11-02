## 46. Signals

**Status:** Scheduled on 2026-10-15 (row 7.8), after the bootstrap (§18, port
step 8, done), and item 20 of the list after 0.8.0 in the
[roadmap](../roadmap/README.md). 46a and 46b may run earlier when no other VM
PR is waiting. Nothing is implemented yet.

The owner asked for a way to catch the OS stop signal in an Agentica program. A
container entrypoint should stop its child, run cleanup and exit with the right
code. The reference is a launcher script that registers and runs a GitHub
Actions self-hosted runner; section 46.4 says how it maps to the proposed API.

### 46.1 Today

The VM has one stop path, and a program cannot take part in it. One `sigaction`
handler covers SIGINT, SIGTERM and SIGHUP (`agc_io_watch_stop`, `vm/loop.c`),
except a signal the VM started as ignored. It only sets atomics and wakes the
loop; the scheduler checks it between turns (`check_stop`, `vm/task.c`), the run
ends as an exit with code 128 + signal, and `agc_launch_settle`
(`vm/launch.c`) kills the children, flushes and raises the signal again with its
default action. A second signal is recorded until the children are stopped; a
3-second `alarm` (`STOP_GRACE_SECONDS`) bounds that wait. See
`docs/vm/14-core-invariants.md` §14.4 and `docs/vm/10-io-scheduler.md` §10.2.2.

- No builtin reports a signal and no task sees one. The VM signals only the
  children it started (`signal_child`); it has no call to signal another pid or
  a process group.
- `Process.spawn` and `spawn_captured` leave the child in the VM's process group
  and session. `Process.close` and the end of the run signal only the child's
  pid: SIGKILL for `spawn`; SIGTERM then SIGKILL one second later for
  `spawn_captured`. Descendants are not reached
  (`site/content/library/io-and-system/process.md`).
- `Process.wait` returns the exit code, or 128 + signal for a killed child, so
  exit 143 and death by SIGTERM look the same. It returns when the child has
  exited and its stderr is at EOF (`docs/vm/10-io-processes.md`), so a
  grandchild holding the stderr pipe delays it.
- The VM has no `uv_signal_t` watcher for the stop signals; libuv has its own
  inside `uv_spawn` (SIGCHLD). A past hang came from a program reading the
  loop's signal pipes; the guard is `private_pipe` in `vm/files.c` (PR #162). Any
  new watcher must respect it and libuv's shared signal lock.
- The VM reaps only the children libuv spawned, so a grandchild re-parented to a
  VM running as PID 1 stays a zombie (`docker run --init` avoids this).

### 46.2 Goals

1. **The entrypoint, end to end.** A program starts a child, catches TERM or
   INT, and stops the child. It waits for the child with a deadline and kills
   the child's group if the child is late. Then it runs cleanup, which may spawn
   a process or make an HTTP call. Last, it exits with the right code. The
   gh-runner script is the reference (46.4).
2. **A graceful HTTP server stop.** Stop accepting new connections, and let the
   requests in flight finish, within a deadline. Today `HTTP.close_server` stops
   accepting, closes every connection and cancels the handlers. So it is not
   graceful. A drain is a separate change in `std/http` (46.7, phase 46d).
3. **A CLI that cleans temp files on Ctrl-C.** The program subscribes to INT,
   removes its temp files and exits with 130 (128 + 2).
4. **No program code in a C signal handler.** The handler only records the
   signal. The program sees a signal as a value on a channel, and tasks handle
   it.

Non-goals: reloading program state on SIGHUP (the VM does nothing special, see
46.8, question 6), Windows (46.3.9), and signals to processes of another user
(the OS decides those).

### 46.3 Design proposal

The design fits the task and channel model. A signal is a value that a task
receives. There are no callbacks, as in Go's `signal.Notify`. The names below
are proposals. Builtin names and error codes follow the existing rules.

#### 46.3.1 Subscribing

```text
Signal.channel(signals: List[Signal]) -> Result[Channel[Signal]]
Signal.number(sig: Signal) -> Int
```

`Signal` is a builtin enum with no payloads, like `LogLevel`
(`compiler/catalog/builtins_data.agc`). Its variants are `Signal.Term`,
`Signal.Int`, `Signal.Hup`, `Signal.Usr1`, `Signal.Usr2`, `Signal.Quit` and
`Signal.Kill`. The spelling follows `Await.TimedOut` and `LogLevel.Info`.
ALLCAPS names are constant names, so they are not used here. 46a checks that
`Signal.Int` is accepted, since `Int` is also a builtin type name.

- The first five can be subscribed to. `Quit` is the VM's force path (46.3.3),
  so it is never delivered. `Kill` cannot be caught by any program. Subscribing
  to `Quit` or `Kill` is a runtime error at the argument,
  `RUNTIME-INVALID-SIGNAL`. An empty list is `error("signal: no signals")`. A
  duplicate in the list is ignored.
- The channel holds one pending value per signal, so its capacity is five, the
  number of subscribable signals. A value is queued only when that signal has no
  pending value. So nothing is dropped, and nothing blocks in the loop. The cost
  is that counts are lost. A program that needs every press must use another
  design.
- `Signal.number(Signal.Term)` is 15 on Linux. It lets a program write
  `System.exit(128 + Signal.number(Signal.Term))`.

The channel is better than `Signal.wait(names, timeout_ms)`. A blocking wait
drops a signal that arrives before the call. A subscription queues the signal
from the moment the program subscribes. The channel also fits the timeouts that
the programs already use with `Channel.recv` and `Task.await`. The
recommendation is in 46.8, question 1.

The name `Signal` is a risk, and the 46a PR decides it (open question 12 of
46.8). (1) `tests/fixtures/vm/http-server-close.agc` has `struct Signal`; a user
type with a builtin name is `CHECK-REDEFINED-NAME`, so the reserved name is
breaking and the fixture is renamed. (2) No builtin takes an enum as a
parameter today (`Await` is only a return value, with special checker code);
`List[Signal]` as a parameter is new. (3) A builtin enum that shares its name
with a function namespace has no precedent: the module resolver reads `Name.x`
as an enum constructor when `Name` is a builtin enum, so `Signal.channel(...)`
would be read as a constructor. Options: (A) keep `Signal.channel` and
`Signal.number` and make the resolver resolve a function first (a front-end
change); (B) move them to `System.subscribe(signals)` and
`System.signal_number(sig)` and keep `Signal` as an enum only. Recommendation:
(B). The rest of this section uses the names of (A).

#### 46.3.2 Ownership, lifecycle and the handler

- **Owner.** The subscription belongs to the task that opened it, like any
  handle (`docs/grammar/06c-tasks-and-tests.md`). It ends when that task ends in
  any way (return, crash or cancel), or when the program calls `Channel.close`
  on the channel. Values already queued are still received. After that, `recv`
  returns `channel: closed`.
- **Default returns.** When the last subscription to a signal ends, the default
  action comes back. If a value of that signal is still pending at that moment,
  it goes to the stop path (46.1) then. It is never lost.
- **While subscribed.** A subscribed signal does not start the stop path. It is
  queued on the channel. A signal that several subscriptions want goes to each
  of them.
- **Driver gone.** A driven VM whose driver is gone does not deliver a signal.
  It takes the default path, as in 46.1. This covers the `PR_SET_PDEATHSIG`
  signal (46.3.10).
- **Channel rules.** `Channel.send` on a signal channel gives `error("signal:
  channel is read only")`, since only the VM sends.
- **The masks and the handler.** The VM keeps two atomic masks, one bit per
  signal number: `subscribed` (written by the loop, read by the handler) and
  `pending` (set by the handler for a subscribed signal, which then wakes the
  loop with the existing `uv_async_send`). The loop clears the bit and offers the
  value to each subscription with a send that never waits. The subscription
  table belongs to the I/O thread and changes by a request through the inbox
  (`docs/vm/16-architecture.md`). A signal with no subscription takes the stop
  path as today. No `uv_signal_t` watcher is added: libuv's watchers share a lock
  and a pipe (46.1), and libuv restores the default action when it stops the
  last watcher of a signal, so the VM would have to reinstall its handler each
  time.
- **The stop set.** `stop_signals[]` in `vm/loop.c` grows from INT, TERM and HUP
  to USR1, USR2 and QUIT, and `agc_io_block_stop` blocks the same list in
  worker threads. Without a subscription USR1 and USR2 now take the stop path
  (children stopped, output flushed, death by that signal) instead of ending
  the process at once and leaving the children running: a behavior change that
  the 46a CHANGELOG entry says.
- **Writes.** The handler has no `SA_RESTART`, so a blocking stdout or stderr
  write interrupted by a handled signal returns EINTR. Today `write_failed`
  (`vm/output.c`) treats EINTR as a stop only when a stop signal is set, and
  otherwise reports `RUNTIME-INTERNAL`, which would fail the program on a
  handled TERM. 46a retries an EINTR write for the rest of its bytes after
  clearing the stream's error flag; while it is retried a handled signal waits,
  and only a stop signal ends it.
- **Ignored at start.** A signal that the VM started as ignored (for example
  under `nohup`) keeps that state. The handler install skips it.
  `Signal.channel` returns `error("signal: ignored when the program started")`
  when any requested signal is in that state. It does not override the ignore,
  because the parent chose that state.

#### 46.3.3 Later signals

The gh-runner ignores every signal after the first. Today a second stop signal
ends the run after the children stop (46.1). The recommendation is to deliver
every Term, Int, Hup, Usr1 and Usr2 to the channel while a subscription exists,
and to keep Quit as the force path (46.8, question 3).

Quit is never delivered. It always takes the stop path: the children stop, the
output and files are flushed, and the process exits with status 131 by
`_exit(131)` (async-signal-safe) without raising the signal again, so there is
no core dump and a parent sees exit status 131, not death by a signal. A second
Quit during that end also exits with 131. `agc_launch_settle` and the stop
handler special-case it. Today Quit is not handled (its default action dumps
core and leaves the children running), so it joins the stop set in 46a. A
program that ignores later signals can still be stopped by Quit (Ctrl-\) or by
its parent's SIGKILL.

#### 46.3.4 The grace alarm

`STOP_GRACE_SECONDS` bounds only the default path (a second default stop while
the children are stopped). A handled signal never arms it, so a program that
handles TERM and needs ten seconds of cleanup is not cut. The alarm can still cut
a program on its default path, for example on a second Quit. The parent's
SIGKILL is the parent's timer (`STOP_TIMEOUT` in the gh-runner script); the VM
adds no deadline for a handled stop.

#### 46.3.5 Sending to a child

```text
Process.signal(p: Process, sig: Signal) -> Result[Void]
```

This sends the signal to the child's pid. It works for a child from
`spawn_group` too, since its leader is that pid. An exited or closed child gives
an error Result. The rule for `Process.wait` does not change, so it still
returns 128 + signal for a child killed by a signal.

`Process.wait` does not change: it still returns 128 + signal for a killed
child. A builtin that returns the signal number is the smallest change if a
program ever needs it; it is not proposed now.

#### 46.3.6 Process groups

```text
Process.spawn_group(command: String, args: List[String], dir: String, timeout_ms: Int) -> Result[Process]
Process.signal_group(p: Process, sig: Signal) -> Result[Void]
```

- **Start.** `spawn_group` starts the child in a new session (`setsid`), so its
  pid is the group id, as `start_new_session=True` does in Python. It takes
  `dir`, as `spawn_captured` does. The command still resolves against the
  program's working directory, not `dir`
  (`site/content/library/io-and-system/process.md`).
  So a program uses an absolute path.
- **Streams: the child inherits them.** The child inherits the VM's stdin,
  stdout and stderr, as Python's `Popen` does with no arguments: no pipe, so
  nothing can stall, and its output goes straight to the container's logs. The
  program cannot read that output (`Process.read_line`, `output`, `send` and the
  channel calls give an error Result). The alternative, a pump task copying a
  pipe, must always run (a pump nobody reads fills the pipe after 64 KiB and
  stalls run.sh), so it is more machinery for the same result. The cost of
  inheriting: the child shares stdin with the program.
- **Wait.** A `spawn_group` child has no pipes, so `Process.wait` returns when
  the leader exits. The stderr rule of 46.1 does not apply to it. Piped children
  keep today's rule.
- **Signal the group.** `signal_group` sends the signal to the whole group
  (`kill(-pid, sig)`). It is an error for a child that was not made by
  `spawn_group`. It is also an error once the leader has been reaped, and the VM
  knows that from its own state. While the leader exists, its pid cannot be
  reused, so the group id is safe. After the leader is reaped the group may
  still have members, but the VM does not guess in that case, and it refuses.
- **Close and the end of the run.** `Process.close` and the end of the run send
  to the whole group for a `spawn_group` child. They send SIGKILL to the group.
  The children inherit their streams and are never captured, so there is no
  SIGTERM step. Other children are unchanged. This closes the "descendants are
  not covered" limit for group children only.

#### 46.3.7 Signals to a pid that is not a child

```text
System.signal(pid: Int, sig: Signal, comm: String) -> Result[Void]
```

The gh-runner finds `Runner.Listener` by scanning `/proc/*/comm`, then sends it
SIGTERM. The listener is a grandchild under run.sh, not a child of the program.
The scan is possible today (`Dir.list("/proc")` and `File.read_text`).
Signalling is not. There are three ways to make it work.

- **(a) Signal the run.sh group.** This is not the same. The group may also hold
  the job worker, which would then get TERM too. It changes what the runner
  does, so it is rejected.
- **(b) `System.signal(pid, sig)` with no check.** This is unsafe. A pid read
  from a scan can be reused by another process before the signal is sent. The
  program would then signal a stranger. It is rejected.
- **(c) `System.signal(pid, sig, comm)` through a pidfd.** This is proposed.

How (c) works. The VM opens a pidfd for the pid with `pidfd_open`. From then on
the pidfd names one process. The VM reads `/proc/<pid>/comm` and compares it
with `comm`. If they match, the VM sends the signal with `pidfd_send_signal` on
that same pidfd. So the signal can only reach the process the pidfd names. The
name check is exact while that process is alive. If the process has exited and
been reaped, `pidfd_send_signal` fails with ESRCH, and nothing is signalled,
even when a later process has the same pid number. So the VM never relies on the
pid number staying unused. The name is the only identity the VM can offer. A
program that matches a name that another process also has still signals that
process.

Kernel and libc. `pidfd_open` needs Linux 5.3, and `pidfd_send_signal` needs
5.1. The release is built against glibc 2.28 (`docs/vm/08-loader-and-cli.md`
§9), and that glibc has no wrappers for either call (they arrived in 2.36). So
the VM calls `syscall()` with hand-defined numbers. It probes once, at the first
call, by opening a pidfd for its own pid. ENOSYS and EPERM (a seccomp filter in
a container) mean unavailable, and the call returns `error("signal: pidfd is
unavailable")`. A container runs the host's kernel, so the host decides. Debian
10 (4.19) and RHEL 8 (4.18) stock kernels lack `pidfd_open`. Vendor kernels may
backport it, so the probe decides. The fallback is 46.8, question 11.

Rules.

- `comm` is required. It is compared in the kernel's form, which keeps 15 bytes.
  `Runner.Listener` is exactly 15 bytes.
- A pid of zero or less is an error. The VM's own pid is an error too, so a
  program cannot signal itself by mistake.
- The kernel checks the user. A process of another user gives the permission
  error.

The permission for this call is in 46.3.8.

#### 46.3.8 Permissions

- `Signal.channel` needs no flag. It only affects the program that asks for it,
  and a program can already stop itself.
- `--deny-run` turns off `Process.spawn_group`, as it does `Process.spawn`.
- `Process.signal` and `Process.signal_group` need nothing more. They only work
  on children that the program already has, and it had to be allowed to start
  them.
- `--deny-run` turns off `System.signal`. It can reach any process of the same
  user. Starting programs already gives that class of power.

The recommendation (46.8, question 5) is to gate `System.signal` and
`spawn_group` with `--deny-run`, and to leave `Signal.channel` open.

#### 46.3.9 Platforms

- Linux first, on the glibc 2.28 release baseline (46.3.7). `Signal.Kill` cannot
  be caught or blocked, so it is a value to send, never one to receive. SIGSTOP
  is not in the enum.
- `spawn_group`, `signal_group` and `System.signal` need Linux, for process
  groups and pidfd. Other systems build none of them, as they build none of the
  other `Process` channel builtins (`docs/vm/10-io-processes.md`).
- Windows would map Ctrl-C and Ctrl-Break to INT and TERM later. A
  Windows console has no POSIX process groups. Its group story would need a job
  object, as `docs/vm/08-loader-and-cli.md` plans. Not designed here.

#### 46.3.10 Tests and children

- A driven VM sets `PR_SET_PDEATHSIG` to SIGTERM (`agc_launch_bind`). When the
  driver dies that orphan signal takes the default path (46.3.2): the VM kills
  its children and exits, with no cleanup, since no driver is left to wait for.
- `agentica test` stops each scenario's VM with `Process.close`
  (`stdlib/test/runner.agc`): SIGTERM, then SIGKILL one second later. A test
  program that subscribes to TERM and needs more than a second to clean up is
  killed by the runner, which owns the timeout.
- Programs without a subscription keep the stop behavior that
  `tests/test_vm_stop.py` checks; USR1, USR2 and QUIT cases are new, in 46a.

#### 46.3.11 Layers

The code has no `uv_signal` watchers, so the stop state, the two masks, the
handler and the subscription table stay in `vm/loop.c` (core; a service reaches
the loop only through the port, which has no stop signals). The channel offer
(a send that never waits, one value per signal, end of the owning task) and the
`Signal.channel` builtin go in `vm/channel.c`; the EINTR retry in
`vm/output.c`; `Process.signal`, `signal_group`, `spawn_group`, the group close
and `System.signal` (libuv and plain syscalls, pidfd through `syscall()`) in
`vm/process.c`, a service (`docs/vm/15-layers.md`); the rows and the enum in
`compiler/catalog/builtins_data.agc`.

### 46.4 The entrypoint in Agentica

The `Supervisor` and `main` flow of the launcher, in the proposed API (it does
not compile today), maps from Python like this:

- `handle_signal` becomes a task that reads the first value of a
  `Signal.channel` for `Signal.Term` and `Signal.Int`. Later values stay queued
  and unread, which is the "ignore later signals" rule.
- The 1-second poll of `Popen.wait` becomes `Task.await(finished, 1000)`, where
  `Await.TimedOut` is the tick; a timed-out `Process.wait` is repeated.
- `start_new_session=True` becomes `Process.spawn_group`; `os.killpg(pid,
  SIGKILL)` becomes `Process.signal_group`; `os.kill` on each listener (found
  by scanning `/proc/*/comm`) becomes `System.signal(pid, sig, comm)`.
- The stop deadline is a monotonic millisecond value set at the first signal.
- The program subscribes before the child starts, for the whole run, so a TERM
  during deregistration is queued and ignored.
- After its own stop the program exits 0; otherwise it exits with the child's
  code. A shell-style exit is `System.exit(128 + Signal.number(Signal.Term))`.
- The stop starts at the next tick (about one second). A 100 ms tick costs more
  wake-ups, and the owner can choose it.
- A signal before the subscription takes the default path: it stops the
  `config.sh` child and ends the process by that signal.

### 46.5 What the entrypoint needs

Missing, and in §46: stop signals TERM and INT (`Signal.channel`, 46.3.1);
signal a child's group (`Process.signal_group`, 46.3.6); run run.sh as a session
leader with its output (`Process.spawn_group`, 46.3.6); signal a listener by pid
(`System.signal`, 46.3.7). Missing or partly, outside §46 (separate changes):
`File.copy` that keeps the mode, an `exists?`/access check, `System.hostname`
(use `HOSTNAME` or `/etc/hostname`), reaping orphans as PID 1 (`docker run
--init`, 46.8 question 10). The rest of the launcher exists today.

### 46.6 Tests (for later)

Hermetic, Linux only, following the process-test rule of `AGENTS.md`: a handled
TERM runs the cleanup and exits 0; TERM is forwarded to a `spawn_group` child; a
second TERM is ignored; QUIT exits 131 as a normal exit, leaves no children and
writes no core file; a child that ignores TERM is killed with its group after
the deadline; a signal to a pid carries the right name and a wrong name is an
error that leaves the process alive; INT ignored at start gives the `ignored`
error and stays ignored.

### 46.7 Phases

- **46a: subscription.** The `Signal` enum and its names (46.3.1; the PR chooses
  between (A) and (B)); the stop set grows by USR1, USR2 and QUIT; writes retry
  on EINTR (46.3.2); Quit takes the `_exit(131)` path (46.3.3). **Breaking:**
  `Signal` becomes a reserved builtin name.
- **46b: sending.** `Process.signal`, `spawn_group`, `signal_group` and
  `System.signal`, with the pidfd probe and `--deny-run`; the group close and the
  end-of-run group kill for group children.
- **46d: graceful HTTP stop.** A drain in `std/http` (stop accepting, wait for
  the handlers up to a deadline), in Agentica, after 46b by the owner's order.
  (46c, the Racket driver, is gone: an ordinary run is the process of the
  binary.)
- Outside §46: `File.copy` that keeps the mode, `System.hostname`, PID 1
  reaping (46.8, question 10).

### 46.8 Decisions

Decided on 2026-10-15 as recommended, except question 12. Options not taken are
named.

1. **API shape:** a `Signal.channel` subscription, which queues values from the
   moment it is made. Not a blocking `Signal.wait(names, timeout_ms)`: it drops a
   signal that arrives before the call and needs a task per wait point.
2. **Names:** the builtin enum `Signal` (a typo is a check error), as
   `LogLevel` does; not strings.
3. **Later signals:** (B), the program decides: while a subscription exists every
   Term, Int, Hup, Usr1 and Usr2 goes to the channel, and Quit is the force path
   (stops the children, flushes, exit 131). It matches the gh-runner and Go's
   `signal.Notify`, and the VM never leaves a child behind. The hard stop belongs
   to the parent (Docker's SIGKILL after 10 seconds, `Process.close`). The cost:
   a direct `agentica run` can only be stopped by Quit or SIGKILL, and Ctrl-\ is
   less known than Ctrl-C twice, so the site page must say so. Not (A) (as
   today) and not (C) (a repeat of the same signal within 3 seconds forces the
   exit; the fallback if Ctrl-C twice must work).
4. **Grace alarm:** kept for the default path only; a handled stop has no VM
   deadline. Not a grace per subscription.
5. **Permissions:** no flag for subscribing (it affects only the program);
   `--deny-run` for `spawn_group` and `System.signal` (a pid signal reaches other
   processes, the class `--deny-run` covers). Not a new `--deny-signal`.
6. **SIGHUP reload:** delivery only. HUP can be subscribed to; the VM reloads
   nothing and the program decides.
7. (Moot: no Racket driver.)
8. **Pid API:** `System.signal(pid, sig, comm)` with a pidfd and the name check.
   Not a check-less `System.signal(pid, sig)` (pid reuse), and not a
   `Process.attach(pid, comm)` handle (`Process.close` would kill a process the
   program does not own).
9. **Stdin of group children:** inherited, as Python does (the program must not
   read stdin while such a child runs); not `/dev/null`.
10. **Reaping orphans as PID 1:** document `docker run --init`; the VM would need
    `waitpid` on pids it does not own, a separate decision.
11. **No pidfd:** refuse with `error("signal: pidfd is unavailable")`. Not
    `kill()` after the name check: the window can signal a stranger. The
    gh-runner still ends after its deadline, since the group kill reaches a
    listener left in run.sh's group.
12. **The name `Signal`:** the options (A) and (B) of 46.3.1. **Decided
    (2026-10-15):** (B) is the starting point, not a final choice; the 46a PR
    makes the final choice, with a spike on the enum parameter. The fixture
    rename and the `**Breaking:**` entry happen under either.

### 46.9 Implementation (row 7.8)

One PR per item; 46a and 46b are VM C code and may run earlier, when no other VM
PR is waiting. Done when: a program handles TERM, INT, HUP, USR1 and USR2 and
stops its children before it exits, with QUIT as the force path; it signals its
own children and a pid it did not start; `std/http` drains its handlers on a
stop; and the tests of 46.6 hold.
