## 46. Signals

**Status:** Scheduled on 2026-10-15 in [phase 27](../roadmap/27-signals.md),
after the bootstrap of §35 (step 8). 46a and 46b may come earlier when no
other VM PR is waiting. Nothing is implemented yet.

The owner asked for a way to catch the OS stop signal in an Agentica program. A
container entrypoint should stop its child, run cleanup and exit with the right
code. The reference is a real launcher:
`/home/sonic182/apps/gh-runner/entrypoint.py`, a Python script that registers
and runs a GitHub Actions self-hosted runner. Section 46.4 is its Agentica
version. This section covers what the VM does today (46.1), the goals (46.2),
the proposal (46.3), the example (46.4), the gaps (46.5), the tests (46.6), the
phases (46.7) and the open questions (46.8).

### 46.1 Today

The VM has one stop path. A program cannot take part in it.

- **The handler.** `vm/loop.c` installs one `sigaction` handler for SIGINT,
  SIGTERM and SIGHUP. `agc_io_watch_stop` does this, and `run()` in `vm/main.c`
  calls it. The handler skips a signal that the VM started as ignored. It sets
  atomics and wakes the loop with `uv_async_send`. It never runs program code.
- **The first signal.** The handler stores it in `stop.signal`. The scheduler
  checks it between turns (`check_stop` in `vm/task.c`). The run then ends as an
  exit with code 128 + signal (`agc_stop` in `vm/interp.c`). `end_run` in
  `vm/main.c` kills the children, flushes the output and the files, and raises
  the signal again with its default action. So the process dies by that signal.
  See `docs/vm/14-core-invariants.md` §14.4 and `docs/vm/10-io-scheduler.md`
  §10.2.2, "Stop signals".
- **The second signal.** While the children are still being stopped, a second
  signal is only recorded. The VM ends as soon as the children are stopped. A
  3-second `alarm` (`STOP_GRACE_SECONDS` in `vm/loop.c`) bounds that wait. So a
  second signal does not end the VM at once. It waits for the children first. A
  driven VM whose driver is gone treats even the first signal as a second one.
- **No program view.** No builtin reports a signal, and no task ever sees one.
  `src/builtins.rkt` has no signal builtin and no function that sends a signal.
- **Children.** `Process.spawn` and `Process.spawn_captured` leave the child in
  the VM's own process group and session. `Process.close` and the end of the run
  signal only the child's pid. They send SIGKILL for `spawn`. For
  `spawn_captured` they send SIGTERM, then SIGKILL one second later
  (`signal_child` and `shut` in `vm/process.c`). Descendants are not reached.
  `docs/grammar/06d-io-and-network.md` says so: "their descendants are not
  covered".
- **Exit status of a child.** `Process.wait` returns the exit code. A child
  killed by a signal returns 128 + signal (`finished` in `vm/process.c`). So a
  child that exits with 143 and a child killed by SIGTERM look the same.
- **Wait and stderr.** `Process.wait` returns when the child has exited and its
  stderr is at EOF (`docs/vm/10-io-processes.md`). A grandchild that keeps the
  stderr pipe open delays it. A timed-out wait returns `error("network:
  operation timed out")` and keeps the child (`agc_stream_timed_out`, defined in
  `vm/stream.c`).
- **Sending a signal.** The VM signals only the children it started
  (`uv_process_kill` in `signal_child`). It has no call to signal another pid,
  and no call to signal a process group.
- **libuv.** The VM has no `uv_signal_t` watcher for the stop signals.
  `docs/vm/15-layers.md` says that `process.c` has no signal watchers. libuv has
  its own signal watcher inside `uv_spawn`, for SIGCHLD. A past VM hang came
  from a program that read the loop's own signal pipes. The guard is
  `private_pipe` in `vm/files.c`, from PR #162 (2026-10-13). Any new watcher
  must respect that guard and libuv's shared signal lock.
- **The driver (until step 8d-2).** `agentica file.agc` ran the VM under a
  Racket driver (`src/main.rkt`, `src/vm-launch.rkt`). The driver handled
  SIGINT, SIGTERM and SIGHUP as Racket breaks (`call-noting-break`). On a break
  it waited up to 2 seconds for the VM. Then it sent SIGTERM, waited 2 more
  seconds, and sent SIGKILL (`stop-vm`). If the driver was PID 1 in a
  container, the VM got its first signal 2 seconds after the stop. Since 8d-2
  an ordinary run is the process of the binary, so there is no driver and no
  delay: the stop reaches the program at once. Only `racket src/main.rkt` (the
  oracle) still has the driver.
- **A compiled run.** `agentica compile FILE.agc -o FILE.agcb` writes bytecode.
  `agentica run [--allow-run] -- FILE.agcb` runs it (usage in `vm/agentica.c`,
  and `docs/vm/08-loader-and-cli.md` §9). The stop reaches the program at
  once, as for any run of the binary.
- **PID 1.** The VM reaps the children that libuv spawned. Nothing in `vm/`
  calls `waitpid` on other pids. So a grandchild that is re-parented to a VM
  running as PID 1 stays a zombie. `docker run --init` avoids this.

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

The headline use case used to need `agentica-vm` run directly, or phase 46c:
under `agentica file.agc` the Racket driver waited 2 seconds before it signaled
the VM (`stop-vm` in `src/vm-launch.rkt`), so a handled stop in a container had
about 2 seconds. Since step 8d-2 no run has that delay.

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
(`src/builtin-types.rkt`). Its variants are `Signal.Term`, `Signal.Int`,
`Signal.Hup`, `Signal.Usr1`, `Signal.Usr2`, `Signal.Quit` and `Signal.Kill`.
The spelling follows `Await.TimedOut` and `LogLevel.Info`. ALLCAPS names are
constant names from §44, so they are not used here. 46a checks that
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

The name `Signal` is a risk, and the 46a PR decides it, with this evidence. (1)
`tests/fixtures/vm/http-server-close.agc` has `struct Signal` (line 3). A user
type with a builtin name is `CHECK-REDEFINED-NAME`, so the reserved name is a
breaking change, and the fixture is renamed. (2) No builtin takes an enum as a
parameter today. `Await` is only a return value, and it has special checker code
(`src/checker.rkt`, the `task-await-timeout` case). `List[Signal]` as a
parameter is new. (3) A builtin enum that shares its name with a function
namespace has no precedent. `src/modules.rkt` (lines 347 and 388) reads `Name.x`
as an enum constructor when `Name` is a builtin enum. So `Signal.channel(...)`
would be read as a constructor. The options are: (A) keep `Signal.channel` and
`Signal.number`, and make `src/modules.rkt` resolve a function first, which is a
front-end change in both front ends; (B) move them to
`System.subscribe(signals)` and `System.signal_number(sig)`, and keep `Signal`
as an enum only. The recommendation is (B), which avoids the `src/modules.rkt`
clash. The enum parameter (no builtin takes one today) is checked with a spike
in 46a (46.8, question 12). The rest of this section, the example included, uses
the names of (A). Under (B) they change to `System.subscribe` and
`System.signal_number`.

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
  signal number. `subscribed` is set for each signal with a live subscription.
  The loop writes it, and the handler reads it. `pending` is set by the handler
  for a subscribed signal. The handler then wakes the loop with the
  `uv_async_send` that it already uses. The loop clears the bit and offers the
  value to each subscription, with a send that never waits. The subscription
  table belongs to the I/O thread, and a builtin changes it with a request
  through the inbox (`docs/vm/16-architecture.md`). The handler reads only the
  masks. A signal with no subscription goes to the stop path, as today. No libuv
  signal watcher is added. The `uv_signal_t` idea was checked and rejected.
  libuv's signal watchers share a lock and a pipe (46.1). libuv also puts back
  the default action when it stops the last watcher of a signal, so the VM would
  have to reinstall its own handler each time.
- **The stop set.** `stop_signals[]` in `vm/loop.c` (lines 375 to 378) grows
  from INT, TERM and HUP to also USR1, USR2 and QUIT. `agc_io_block_stop` blocks
  the same list in worker threads, so these signals reach the loop thread, as
  the first three do. Without a subscription, USR1 and USR2 now take the stop
  path. The children stop, the output and the files are flushed, and the process
  dies by that signal, as TERM does. Today they end the process at once by their
  default action and leave the children running. This is a behavior change, and
  the 46a CHANGELOG entry says so.
- **Writes.** The handler has no `SA_RESTART`. A blocking write to stdout or
  stderr that a handled signal interrupts returns EINTR. Today `write_failed`
  (`vm/output.c`, lines 38 to 44) treats EINTR as a stop only when a stop signal
  is set. Otherwise it reports `RUNTIME-INTERNAL`, which would fail the program
  on a handled TERM. 46a changes the callers. An EINTR write is retried for the
  rest of its bytes, after the stream's error flag is cleared. While a blocked
  stdout write is retried after EINTR, a handled signal waits until the write
  finishes; only a stop signal ends it.
- **Ignored at start.** A signal that the VM started as ignored (for example
  under `nohup`) keeps that state. The handler install skips it (`vm/loop.c`,
  lines 443 to 446). `Signal.channel` returns `error("signal: ignored when the
  program started")` when any requested signal is in that state. It does not
  override the ignore, because the parent chose that state.

#### 46.3.3 Later signals

The gh-runner ignores every signal after the first. Today a second stop signal
ends the run after the children stop (46.1). The recommendation is to deliver
every Term, Int, Hup, Usr1 and Usr2 to the channel while a subscription exists,
and to keep Quit as the force path (46.8, question 3).

Quit is never delivered. It always takes the stop path. The children stop, the
output and files are flushed as on any stop, and the process exits with status
131 by calling `_exit(131)`. It does not raise the signal again. So it leaves no
core dump, and a parent sees exit status 131, not death by a signal. `end_run`
in `vm/main.c` and `stop_at_once` in `vm/loop.c` special-case Quit this way.
`_exit` is async-signal-safe, so the handler may call it. A second Quit during
that end takes the second-signal path, and it also exits with 131.

Today the VM does not handle Quit. Its default action dumps core and leaves the
children running. So Quit joins the stop set in 46a. A program that ignores
later signals can still be stopped by Quit (Ctrl-\) or by its parent's SIGKILL.

#### 46.3.4 The grace alarm

`STOP_GRACE_SECONDS` bounds only the default path, meaning a second default stop
while the children are being stopped. A handled signal never enters that path,
so the alarm is never armed for it. A program that handles TERM and needs ten
seconds of cleanup is not cut by the alarm.

The alarm can still cut a program on its default path. An example is a second
Quit while the children are being stopped.

The parent's SIGKILL is a different thing. It is the parent's timer, as
`STOP_TIMEOUT` is in the gh-runner script. The VM does not add a deadline for a
handled stop. The program sets its own deadline, as the example does.

#### 46.3.5 Sending to a child

```text
Process.signal(p: Process, sig: Signal) -> Result[Void]
```

This sends the signal to the child's pid. It works for a child from
`spawn_group` too, since its leader is that pid. An exited or closed child gives
an error Result. The rule for `Process.wait` does not change, so it still
returns 128 + signal for a child killed by a signal.

No change to `Process.wait` is needed for the use cases here. The gh-runner
returns 0 after its own stop, and the run.sh code otherwise. If a program ever
needs to tell a signal death from an exit code, the smallest change is a builtin
that returns the signal number. It is not proposed now.

#### 46.3.6 Process groups

```text
Process.spawn_group(command: String, args: List[String], dir: String, timeout_ms: Int) -> Result[Process]
Process.signal_group(p: Process, sig: Signal) -> Result[Void]
```

- **Start.** `spawn_group` starts the child in a new session (`setsid`), so its
  pid is the group id, as `start_new_session=True` does in Python. It takes
  `dir`, as `spawn_captured` does. The command still resolves against the
  program's working directory, not `dir` (`docs/grammar/06d-io-and-network.md`).
  So the example uses an absolute path.
- **Streams: the child inherits them.** The child inherits the VM's stdin,
  stdout and stderr, as Python's `Popen` does with no arguments. The VM makes no
  pipe for it, so nothing can stall, and its output goes straight to the
  container's logs. The program cannot read that output. `Process.read_line`,
  `Process.output`, `Process.send` and the channel calls give an error Result
  for such a child. The alternative is a pump task that copies a pipe into the
  program's output. A pump that no task reads fills the pipe after 64 KiB and
  stalls run.sh. So the pump must always run, which is more machinery for the
  same result. The cost of inheriting is that the child shares stdin with the
  program. A program that reads stdin while the child runs competes with it. The
  example does not read stdin.
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
- `Process.spawn_group` needs `--allow-run`, as `Process.spawn` does.
- `Process.signal` and `Process.signal_group` need nothing more. They only work
  on children that the program already has, and it had to be allowed to start
  them.
- `System.signal` needs `--allow-run`. It can reach any process of the same
  user. Starting programs already gives that class of power.

The recommendation (46.8, question 5) is to gate `System.signal` and
`spawn_group` with `--allow-run`, and to leave `Signal.channel` open.

#### 46.3.9 Platforms

- Linux first, on the glibc 2.28 release baseline (46.3.7). `Signal.Kill` cannot
  be caught or blocked, so it is a value to send, never one to receive. SIGSTOP
  is not in the enum.
- `spawn_group`, `signal_group` and `System.signal` need Linux, for process
  groups and pidfd. Other systems build none of them, as they build none of the
  other `Process` channel builtins (`docs/vm/10-io-processes.md`).
- Windows (paused) would map Ctrl-C and Ctrl-Break to INT and TERM later. A
  Windows console has no POSIX process groups. Its group story would need a job
  object, as `docs/vm/08-loader-and-cli.md` plans. Not designed here.

#### 46.3.10 Tests and children

- A driven VM sets `PR_SET_PDEATHSIG` to SIGTERM (`bind_to_driver` in
  `vm/main.c`). When the driver dies, the VM gets SIGTERM. That signal is an
  orphan signal, so the rule of 46.3.2 sends it down the default path. The VM
  kills its children and exits. The program does not get to clean up in that
  case, because no driver is left to wait for.
- `agentica test` runs each scenario's VM as a captured child. The runner stops
  it with `Process.close` (`stdlib/test/runner.agc`). That sends SIGTERM, and
  one second later SIGKILL. A test program that subscribes to TERM and needs
  more than one second to clean up is killed by the runner. That is the right
  result, because the runner owns the timeout. A test program should subscribe
  only if it stops within a second.
- The programs without a subscription keep the stop behavior that
  `tests/test_vm_stop.py` checks. That file covers TERM, INT and HUP. The USR1,
  USR2 and QUIT cases are new, in 46a.

#### 46.3.11 Layers

The first idea was a service on the loop thread, using the existing `uv_signal`
watchers. The code has no such watchers, so the placement changes
(`docs/vm/15-layers.md`).

- The stop state, the two masks and the handler stay in `vm/loop.c`. That file
  is core. The subscription table lives there too. A service reaches the loop
  only through the port (`agc_io_uv`). The stop signals are not part of the
  port, so a service cannot touch the stop state.
- The channel offer goes in `vm/channel.c`, which is core. It is a send that
  never waits, with the one-value-per-signal rule and the end of the owning
  task. The `Signal.channel` builtin goes there too, next to the other Channel
  builtins.
- The EINTR retry for writes goes in the callers in `vm/output.c`, which is
  core.
- `Process.signal`, `Process.signal_group`, `Process.spawn_group`, the group
  close and `System.signal` go in `vm/process.c`. That file is a service. It may
  use libuv and plain syscalls, including the pidfd calls through `syscall()`.
- The builtin rows go in `src/builtins.rkt`, and the enum data goes in
  `src/builtin-types.rkt`. Row 7.2.7 of the roadmap allows those rows. The
  compiler catalog is generated from both files (46.7).

No `uv_signal_t` watcher is added (46.3.2).

### 46.4 The entrypoint in Agentica

The program below is the `Supervisor` and the `main` flow of the gh-runner
script, in the proposed API. It does not compile today. `Signal`,
`Signal.channel`, `Signal.Term`, `Process.spawn_group`, `Process.signal_group`,
`System.signal` and `File.copy` do not exist yet. `Path.remove` does: it came
with the OS builtins of the BDD driver port (§35.5, step 7a), as
`Path.remove(path, timeout_ms)`, which deletes a file, a link or a directory
tree without following links and treats a missing path as `ok()`. Constants are
functions until module constants (§44) land.

The mapping from Python is short. `handle_signal` becomes `first_signal`. It
returns the first value. Later values stay queued and unread, which is the
Python "ignore later signals" rule. The 1-second poll of `Popen.wait` becomes
`Task.await(finished, 1000)`, where `Await.TimedOut` is the tick. The timed-out
`Process.wait` is repeated inside `wait_exit`. The `STOP_TIMEOUT` deadline is
set in `begin_stop`. `os.killpg(pid, SIGKILL)` becomes `kill_group`. The
`os.kill` on each listener becomes `System.signal`. `deregister` and
`fetch_token` keep their rules.

```agentica
import HTTP from "std/http"
import Logger from "std/logger"

# Proposed API (46a, 46b): Signal, Signal.channel, Process.spawn_group,
# Process.signal_group, System.signal and File.copy. Path.remove exists.
# Constants are functions until module constants (§44) land.

struct Settings
  url: String
  pat: String
  token: String
  name: String
  labels: String
  group: String
  work: String
  state_dir: String
  ephemeral: Bool
  deregister: Bool
end

struct Run
  code: Int
  stopped: Bool
end

def runner_dir() -> String
  return "/home/runner/actions-runner"
end

def stop_timeout_ms() -> Int
  return 25000
end

def config_files() -> List[String]
  return [".runner", ".credentials", ".credentials_rsaparams"]
end

def runner_file(name: String) -> String
  return "#{runner_dir()}/#{name}"
end

def workdir(config: Settings) -> String
  return "#{runner_dir()}/#{config.work}"
end

def env_or(name: String, fallback: String) -> String
  return System.env(name).unwrap_or(fallback)
end

def env_flag(name: String, fallback: Bool) -> Bool
  value = env_or(name, "").trim.downcase
  if value == ""
    return fallback
  end
  return value == "1" or value == "true" or value == "yes" or value == "on"
end

def without_trailing_slashes(text: String) -> String
  result = text
  while result.ends_with?("/")
    result = result.slice(0, result.length - 1)
  end
  return result
end

def settings() -> Result[Settings]
  url = without_trailing_slashes(env_or("GITHUB_URL", "").trim)
  if !url.starts_with?("https://github.com/")
    return error("GITHUB_URL must be https://github.com/OWNER or https://github.com/OWNER/REPO")
  end
  name = env_or("RUNNER_NAME", "")
  if name == ""
    name = env_or("HOSTNAME", "runner")
  end
  ephemeral = env_flag("RUNNER_EPHEMERAL", true)
  return ok(Settings(
    url: url,
    pat: env_or("GITHUB_PAT", ""),
    token: env_or("RUNNER_TOKEN", ""),
    name: name,
    labels: env_or("RUNNER_LABELS", ""),
    group: env_or("RUNNER_GROUP", ""),
    work: env_or("RUNNER_WORKDIR", "_work"),
    state_dir: env_or("STATE_DIR", "/home/runner/state"),
    ephemeral: ephemeral,
    deregister: env_flag("RUNNER_DEREGISTER_ON_STOP", ephemeral),
  ))
end

def api_base(url: String) -> String
  path = url.replace("https://github.com/", "")
  scope = "orgs"
  if path.contains?("/")
    scope = "repos"
  end
  return "https://api.github.com/#{scope}/#{path}"
end

## Asks GitHub for a registration or a removal token.
def fetch_token(config: Settings, kind: String) -> Result[String]
  client = try HTTP.client(HTTP.client_options())
  headers = [
    Header(name: "Accept", value: "application/vnd.github+json"),
    Header(name: "Authorization", value: "Bearer #{config.pat}"),
    Header(name: "X-GitHub-Api-Version", value: "2022-11-28"),
  ]
  reply = HTTP.post(client, "#{api_base(config.url)}/actions/runners/#{kind}", headers, "")
  HTTP.close_client(client)
  response = try reply
  if response.status >= 300
    return error("GitHub answered HTTP #{response.status} for #{kind}")
  end
  body = try JSON.parse(response.body)
  token = try JSON.get(body, "token")
  return JSON.string(token)
end

def registration_token(config: Settings) -> Result[String]
  if config.pat != ""
    return fetch_token(config, "registration-token")
  end
  if config.token != ""
    return ok(config.token)
  end
  return error("set GITHUB_PAT (recommended) or RUNNER_TOKEN")
end

## Runs a command to its end, logs its output and returns its exit code.
def run_checked(command: String, args: List[String], dir: String) -> Result[Int]
  child = try Process.spawn_captured(command, args, dir, 5000)
  output = try Process.output(child, 600000)
  Logger.info(output.stdout.trim)
  Logger.warning(output.stderr.trim)
  return Process.wait(child, 600000)
end

def is_configured() -> Bool
  return File.stat(runner_file(".runner"), 1000).ok?
end

def prepare(config: Settings) -> Result[Void]
  code = try run_checked("sudo", ["chown", "runner:runner", workdir(config)], "/")
  if code != 0
    return error("sudo chown failed with exit code #{code}")
  end
  if config.ephemeral
    Logger.info("ephemeral mode: clearing previous registration and workspace")
    for name in config_files()
      try Path.remove(runner_file(name), 5000)
    end
    entries = try Dir.list(workdir(config), 5000)
    for entry in entries
      try Path.remove("#{workdir(config)}/#{entry}", 5000)
    end
  elsif File.stat("#{config.state_dir}/.runner", 1000).ok?
    Logger.info("restoring registration from #{config.state_dir}")
    for name in config_files()
      source = "#{config.state_dir}/#{name}"
      if File.stat(source, 1000).ok?
        try File.copy(source, runner_file(name), 5000)
      end
    end
  end
  return ok()
end

def configure(config: Settings) -> Result[Void]
  token = try registration_token(config)
  args: List[String] = [
    "--unattended", "--replace", "--url", config.url, "--token", token,
    "--name", config.name, "--work", config.work,
  ]
  if config.labels != ""
    args = args.push("--labels").push(config.labels)
  end
  if config.group != ""
    args = args.push("--runnergroup").push(config.group)
  end
  if config.ephemeral
    args = args.push("--ephemeral")
  end
  Logger.info("registering runner name=#{config.name} ephemeral=#{config.ephemeral}")
  code = try run_checked(runner_dir() + "/config.sh", args, runner_dir())
  if code != 0
    return error("config.sh failed with exit code #{code}")
  end
  if !config.ephemeral
    try Dir.mkdir(config.state_dir, 5000)
    for name in config_files()
      source = runner_file(name)
      if File.stat(source, 1000).ok?
        try File.copy(source, "#{config.state_dir}/#{name}", 5000)
      end
    end
    Logger.info("registration saved to #{config.state_dir}")
  end
  return ok()
end

## Returns the pids of the processes whose name is Runner.Listener.
def listener_pids() -> Result[List[Int]]
  names = try Dir.list("/proc", 5000)
  pids: List[Int] = []
  for name in names
    pid = name.to_i.unwrap_or(0)
    if pid > 0
      comm = File.read_text("/proc/#{pid}/comm", 1000).unwrap_or("")
      if comm.trim == "Runner.Listener"
        pids = pids.push(pid)
      end
    end
  end
  return ok(pids)
end

def stop_listeners() -> Void
  case listener_pids()
    error(message) -> Logger.err(message)
    ok(pids) ->
      if pids.size == 0
        Logger.warning("no Runner.Listener process found")
      end
      for pid in pids
        Logger.info("sending SIGTERM to Runner.Listener pid=#{pid}")
        case System.signal(pid, Signal.Term, "Runner.Listener")
          ok(_) -> Logger.info("signal sent")
          error(message) -> Logger.err(message)
        end
      end
  end
end

## Waits for the first stop signal. Later signals stay queued and are never read.
def first_signal(signals: Channel[Signal]) -> Result[Signal]
  while true
    case signals.recv(1000)
      ok(sig) -> return ok(sig)
      error(message) ->
        if signals.closed?
          return error(message)
        end
    end
  end
  return error("first_signal: the loop only ends by return")
end

## Returns the stop deadline in monotonic milliseconds, or 0 while the runner runs.
## The first signal stops the listeners once and starts the deadline.
def begin_stop(first: Task[Result[Signal]], deadline: Int) -> Int
  if deadline > 0
    return deadline
  end
  case Task.await(first, 1)
    Await.TimedOut -> return 0
    Await.Done(result) ->
      case result
        ok(_) ->
          stop_listeners()
          return Time.monotonic_ms() + stop_timeout_ms()
        error(_) -> return 0
      end
  end
end

## Waits until the child exits. A timed-out wait keeps the child running,
## so the wait is repeated. Any other error ends it.
def wait_exit(child: Process) -> Result[Int]
  while true
    case Process.wait(child, 1000)
      ok(code) -> return ok(code)
      error(message) ->
        # Only the timeout text tells a timed-out wait from other failures.
        if message != "network: operation timed out"
          return error(message)
        end
    end
  end
  return error("wait_exit: the loop only ends by return")
end

def kill_group(child: Process) -> Void
  case Process.signal_group(child, Signal.Kill)
    ok(_) -> Logger.warning("killed the runner's process group")
    error(message) -> Logger.err(message)
  end
end

## Waits for run.sh. The first stop signal starts the stop, and the group is
## killed when the deadline passes.
def supervise(child: Process, signals: Channel[Signal]) -> Result[Run]
  first = Task.spawn(&first_signal, signals)
  finished = Task.spawn(&wait_exit, child)
  deadline = 0
  killed = false
  while true
    case Task.await(finished, 1000)
      Await.Done(outcome) ->
        code = try outcome
        return ok(Run(code: code, stopped: deadline > 0))
      Await.TimedOut -> deadline = begin_stop(first, deadline)
    end
    if deadline > 0 and !killed and Time.monotonic_ms() > deadline
      Logger.err("runner did not stop in #{stop_timeout_ms() / 1000}s, killing it")
      kill_group(child)
      killed = true
    end
  end
  return error("supervise: the loop only ends by return")
end

def remove_runner(config: Settings) -> Result[Void]
  token = try fetch_token(config, "remove-token")
  args: List[String] = ["remove", "--token", token]
  code = try run_checked(runner_dir() + "/config.sh", args, runner_dir())
  if code != 0
    return error("config.sh remove failed with exit code #{code}")
  end
  for name in config_files()
    try Path.remove("#{config.state_dir}/#{name}", 5000)
  end
  return ok()
end

def deregister(config: Settings) -> Void
  if config.deregister and config.pat != "" and is_configured()
    Logger.info("removing runner #{config.name} from GitHub")
    case remove_runner(config)
      ok(_) -> Logger.info("runner removed from GitHub")
      error(message) -> Logger.err(message)
    end
  end
end

def launch() -> Result[Int]
  config = try settings()
  try prepare(config)
  if is_configured()
    Logger.info("runner already registered, skipping configuration")
  else
    try configure(config)
  end
  signals = try Signal.channel([Signal.Term, Signal.Int])
  no_args: List[String] = []
  Logger.info("starting run.sh")
  child = try Process.spawn_group(runner_dir() + "/run.sh", no_args, runner_dir(), 5000)
  run = try supervise(child, signals)
  if run.stopped
    deregister(config)
    return ok(0)
  end
  Logger.info("run.sh exited with code #{run.code}")
  return ok(run.code)
end

def main() -> Void
  case launch()
    ok(code) -> System.exit(code)
    error(message) ->
      Logger.err(message)
      System.exit(1)
  end
end
```

What the program shows:

- It subscribes before run.sh starts, as the Python script installs its handlers
  before `Popen`. The subscription lasts until `main` ends, so a TERM that
  arrives during `deregister` is queued and ignored, as in the Python script.
- The exit code follows the gh-runner script. After its own stop the program
  exits 0. Otherwise it exits with the run.sh code. A runner that follows the
  shell pattern exits with 128 + N, which is one line: `System.exit(128 +
  Signal.number(Signal.Term))`.
- The stop starts within about one second, at the next tick. Python signals the
  listeners inside the handler. A tick of 100 ms costs more wake-ups, and the
  owner can choose it.
- `first_signal` stays parked on the channel. When `launch` returns, `main`
  calls `System.exit`, which ends the run, and the task is cancelled with it.
  Nothing awaits it. If the program kept running, the task would end when the
  channel closes, with `channel: closed` after the queued values.

Differences from `entrypoint.py`:

- **Logging.** Python sets up stdout with timestamps and `LOG_LEVEL`. This
  program logs through `std/logger`, which writes to stderr unless a handler is
  attached. The stdout handler is in 46.5.
- **config.sh output.** Python streams it to stdout while it runs. This program
  captures it and logs it after the process ends.
- **`sudo chown`.** Python runs it only when the workdir is not writable. This
  program runs it every time, because Agentica has no access check (46.5).
- **Signals during prepare and configure.** Python has no handler yet, so a
  TERM kills it. This program takes the default path, which stops the
  `config.sh` child and then ends the process by that signal.
- **Stop latency.** As above, the listeners get TERM within one tick, not inside
  the handler.
- **Trailing slash and empty name.** Both are handled as in Python. A trailing
  slash is stripped from `GITHUB_URL`, and an empty `RUNNER_NAME` falls back to
  the hostname.

### 46.5 What the entrypoint needs, checked against today

The table lists each need of the gh-runner script. It says what exists, what is
missing, and what is out of scope for §46. A row marked "exists" needs no
change. "Partly" means a workaround is possible. "Missing" means the builtin or
the module is not there. The file-operation gaps are real, but they are not
signal work, so they go to their own change.

| Need | Status | Note |
| --- | --- | --- |
| Env vars with defaults | exists | `System.env(name).unwrap_or(default)` |
| Boolean env flags | exists | `String.trim`, `String.downcase` and `==` |
| Stop signals TERM and INT | missing | `Signal.channel` with `Signal.Term` and `Signal.Int` (46.3.1) |
| Signal a child's group | missing | `Process.signal_group` (46.3.6) |
| Run run.sh as a session leader, with its output | missing | `Process.spawn_group` (46.3.6). It inherits the output, as Python does. |
| Run `./config.sh` in a directory | partly | `spawn_captured` takes `dir` but captures stderr. `spawn` has no `dir`. The example captures config.sh and logs it. |
| Spawn `sudo chown` | exists | `Process.spawn_captured` with `--allow-run`. sudo must be present. |
| Scan `/proc` for Runner.Listener | exists | `Dir.list("/proc")` and `File.read_text`. Not yet tested on `/proc`. |
| Signal a listener by pid | missing | `System.signal` through a pidfd (46.3.7) |
| Wait for exit with a deadline | exists | `Process.wait(p, ms)` returns `error("network: operation timed out")` on a timeout and keeps the child. The example repeats the wait. |
| Path: exists check | partly | `File.stat(path, t).ok?`. It follows symlinks and has no `exists?`. |
| Path: unlink | exists | `Path.remove(path, ms)` (§35.5, step 7a). A missing path is `ok`, as with `unlink(missing_ok=True)`. A link is removed itself. |
| Path: rmtree | exists | `Path.remove` covers it, recursively and without following links (`vm/tree.c`). It refuses `/`, `.` and `..`, and trees deeper than 128 levels. |
| Path: copy2 that keeps the mode | missing | `read_text` and `write_text` lose the mode and are text-only. Credential files need their mode. Proposed as `File.copy` (separate change). |
| Path: mkdir -p | exists | `Dir.mkdir` creates parents. |
| Path: iterdir with is_dir and is_symlink | exists | `Dir.list` gives names. `File.lstat` (§35.5, step 7a) does not follow a link and gives `kind` `"link"`; `File.stat` follows it. |
| Path: os.access (writable) | missing | The example runs `sudo chown` every time. A probe write is the workaround. Out of scope. |
| HTTP POST with headers and TLS | exists | `HTTP.post`. System CA certificates by default. |
| JSON token parse | exists | `JSON.parse`, `JSON.get`, `JSON.string`. |
| Logging with timestamps to stdout | exists | `Logger.attach` with a handler that calls `IO.puts(Logger.format_text(event))`. The default handler writes to stderr, and the time is UTC. |
| LOG_LEVEL from the environment | exists | `Logger.set_level`, with a few lines to parse the name. |
| Hostname | missing | No builtin. Use `HOSTNAME` (set by Docker) or `/etc/hostname`. A `System.hostname()` would be one row, if it is needed later. Out of scope. |
| Monotonic clock | exists | `Time.monotonic_ms()` |
| Exit with a code | exists | `System.exit(code)` |
| Reap orphans as PID 1 | missing | Use `docker run --init`. Out of scope (46.8, question 10). |

### 46.6 Testing plan (for later)

The tests are hermetic and use the standard library only. They are Python
`unittest` modules in `tests/test_vm_signals.py`, derived from
`tests.agentica_test.TestCase`. Child programs go in `tests/fixtures/`. The
tests need Linux, and CI fails if they cannot run there. The rule of `AGENTS.md`
for process tests applies: everything is cleaned up, and nothing leaves
localhost. The test cases are these.

1. **A handled stop runs the cleanup.** A VM program subscribes to TERM, starts
   a helper that writes a file, prints a line and exits 0. The test sends
   `os.kill(pid, SIGTERM)`. It checks the printed line, the file and the exit
   code.
2. **Forwarding.** The program starts a child with `spawn_group`. The child
   inherits the output, so the test reads its marker from a file the child
   writes. The child handles TERM by writing the marker and exiting 0. On TERM
   the program forwards the signal with `Process.signal`. The test checks the
   marker and the exit code.
3. **Later signals and the force path.** The program ignores a second TERM and
   keeps running. The test sends a second TERM and checks that the program is
   still alive. Then it sends QUIT. The test checks that the program exits with
   status 131 as a normal exit (not death by a signal), that its children are
   gone (`os.killpg` with signal 0 fails), and that no core file was written.
4. **Escalation.** A child ignores TERM. The program sends Kill to the group
   after its deadline. The test checks that the group is gone.
5. **Pid signals.** A test-owned process is started from a symlink named
   `signal-target` to `/bin/sleep`, so that its comm is that name. The program
   signals it with `System.signal` and the right name, and the signal arrives.
   With a wrong name, the call returns an error and the process is still alive.
6. **Ignored at start.** The test starts the VM with INT ignored, as `nohup`
   does. The program's `Signal.channel` call returns the `ignored` error, and
   INT stays ignored: the process is still alive after `os.kill(pid, SIGINT)`.

The C side is tested in `vm/tests` with `make vm-test`. The tests cover the
masks, the one-value-per-signal rule of the channel, the end of the owning task,
the fan-out to several subscriptions and the `_exit` path of Quit. The existing
`tests/test_vm_stop.py` keeps checking programs without a subscription. Those
are the default-path cases.

### 46.7 Phases

- **46a: subscription.** The `Signal` enum and its names (46.3.1). The option
  (A) or (B) of 46.3.1 is decided in this PR. The masks and the handler change
  in `vm/loop.c`, the stop set grows by USR1, USR2 and QUIT, and the EINTR retry
  goes in `vm/output.c` (46.3.2). Quit takes the `_exit(131)` path (46.3.3). The
  fixture `struct Signal` in `tests/fixtures/vm/http-server-close.agc` is
  renamed, since the reserved name collides with it. The C and Python tests of
  46.6 (cases 1, 3 without the child, and 6). The docs: a Signals subsection in
  `docs/grammar/06c-tasks-and-tests.md`, the reserved name in
  `docs/grammar/04-lexical.md`, the site page, the programming skill (`SKILL.md`
  for the core rule, and a reference file for the detail), and a `CHANGELOG.md`
  entry under `## [Unreleased]`. The entry is marked `**Breaking:**`, since
  `Signal` becomes a reserved builtin name, and it notes the USR1, USR2 and QUIT
  change. The compiler catalog is regenerated in the same PR (before the
  bootstrap: `racket tools/gen-builtins-data.rkt`, checked by
  tests/frontend-catalog-test.rkt; after it, with the generator of that time).
- **46b: sending.** The builtins `Process.signal`, `Process.spawn_group`,
  `Process.signal_group` and `System.signal`, with the pidfd probe and
  `--allow-run`. The group close and the end-of-run group kill for group
  children. The tests of 46.6 (cases 2, 4 and 5). The docs:
  `docs/grammar/06d-io-and-network.md` (Processes), the site Process page
  (`site/content/library/io-and-system/process.md`),
  `.agents/skills/agentica-programming/references/processes.md` with its row in
  `SKILL.md` if needed, `docs/vm/10-io-processes.md` §10.4, and a
  `CHANGELOG.md` entry. The catalog is regenerated in the same PR, as in 46a.
- **46c: the driver.** The driver forwards a break at once to a VM in its own
  process group (46.8, question 7). It needs a test with terminal input first.
  Until then, containers use `agentica compile` and `agentica run` directly
  (46.1). That recipe belongs in the site page.
- **46d: graceful HTTP stop.** A drain in `std/http`: stop accepting, and wait
  for the handlers to finish, up to a deadline. It is a separate change in
  Agentica code, and it does not need the VM work of 46a or 46b in full.
- **Separate changes, outside §46:** `File.copy` that keeps the mode, and
  `System.hostname`. Reaping orphans as PID 1 is also separate (46.8, question
  10). Two of the others are done, in the OS builtins of §35.5 (step 7a):
  `Path.remove`, and the kind check that does not follow links, which is
  `File.lstat`.

The bootstrap question. The compiler catalog exists (§35 step 4, PR #258).
`compiler/builtins_data.agc` is generated from `src/builtins.rkt` and
`src/builtin-types.rkt` by `tools/gen-builtins-data.rkt`, and
`tests/frontend-catalog-test.rkt` fails when it is stale. So each 46a and 46b PR
changes the builtin data and regenerates the catalog in the same PR. Row 7.2.7
allows the table rows and the `vm-builtins` names. The naming choice of 46.3.1
is the case that needs care, since option (A) needs a front-end change. The
sentences above describe landing before the bootstrap. 46a and 46b may land
before the bootstrap when no other VM PR is waiting. 46c changes the driver,
which §35 step 8 ports, so it waits for that port. 46d is Agentica code and
comes after 46b by the owner's order.

### 46.8 Open questions

Each question has options and a recommendation.

1. **API shape: channel or blocking wait.** Options: (a) `Signal.channel`, a
   subscription that queues values from the moment it is made. (b)
   `Signal.wait(names, timeout_ms)`, a blocking call. **Recommendation:** (a). A
   blocking call drops a signal that arrives before the call. It also needs a
   task for each wait point. The channel fits the timeouts that the programs
   already use.

   **Decided (2026-10-15):** the recommendation.

2. **Names: enum or strings.** Options: (a) the builtin enum `Signal`. The
   checker catches a typo. The set is fixed by the VM. (b) strings, such as
   `Signal.channel(["TERM"])`, where a typo shows up only at run time.
   **Recommendation:** (a), as `LogLevel` does.

   **Decided (2026-10-15):** the recommendation.

3. **Later signals.** Options: (A) as today: a second signal ends the run after
   the children are stopped, with the 3-second alarm. (B) the program decides:
   while a subscription exists, every Term, Int, Hup, Usr1 and Usr2 goes to the
   channel. Quit is the force path. It stops the children, flushes as on any
   stop, and exits 131 through `_exit`. (C) the program decides, but a repeat of
   the same signal within 3 seconds forces the exit. **Recommendation:** (B). It
   matches the gh-runner and Go's `signal.Notify`. The VM still never leaves a
   child behind, because Quit stops the children. The hard stop belongs to the
   parent: Docker's SIGKILL after 10 seconds, the driver's SIGKILL, or
   `Process.close`. Under the driver, a stuck program is ended by the driver's
   SIGKILL after about 4 seconds. The cost is that a direct `agentica run`,
   with no driver, can only be stopped by Quit or SIGKILL. Ctrl-\ is less known
   than Ctrl-C twice, so the site page must say so. Option (C) is the fallback
   if the owner wants Ctrl-C twice to work.

   **Decided (2026-10-15):** the recommendation.

4. **The grace alarm.** Options: (a) keep the 3-second alarm for the default
   path only. A handled signal never arms it. (b) a grace per subscription, such
   as `Signal.channel(signals, grace_ms)`. **Recommendation:** (a). A handled
   stop has no VM deadline. The program sets its own deadlines, as the example
   does.

   **Decided (2026-10-15):** the recommendation.

5. **The permission flag.** Options: (a) no flag for subscribing. `--allow-run`
   for `spawn_group` and `System.signal`. (b) `--allow-run` for every signal
   call, including subscribing. (c) a new flag such as `--allow-signal`.
   **Recommendation:** (a). A program that subscribes only affects itself. A pid
   signal reaches other processes, so it belongs to the class that `--allow-run`
   already covers. A new flag adds one more thing to document for little gain.

   **Decided (2026-10-15):** the recommendation.

6. **SIGHUP reload.** Options: (a) out of scope. HUP stays a stop signal only.
   (b) in scope as delivery only. HUP can be subscribed to, the VM does no
   reload, and the program decides. **Recommendation:** (b). It costs nothing
   once 46a exists, and the VM reloads nothing.

   **Decided (2026-10-15):** the recommendation.

7. **The driver's 2-second wait.** Options: (a) keep it, and tell containers to
   run `agentica run` on the compiled file. (b) forward the break at once and
   drop the second copy that comes from the terminal. This is fragile. (c) start
   the VM in its own process group and forward the signal once. Under Ctrl-C the
   terminal reaches only the driver, which forwards one copy. A signal from
   Docker reaches the driver, which also forwards it. **Recommendation:** (a)
   now, and (c) in 46c, after a test with terminal input.

   **Decided (2026-10-15):** the recommendation.

8. **The pid API shape.** Options: (a) `System.signal(pid, sig, comm)` with a
   pidfd and the name check. (b) `System.signal(pid, sig)` with no check, and a
   warning in the docs. (c) a handle from the scan, such as `Process.attach(pid,
   comm)`, returning a non-owning `Process`. **Recommendation:** (a). Option (b)
   is unsafe because of pid reuse. Option (c) makes `Process.close` dangerous,
   since it would kill a process the program does not own.

   **Decided (2026-10-15):** the recommendation.

9. **Stdin of group children.** `spawn_group` children inherit stdin (46.3.6),
   as Python does. Options: (a) inherit, and document that the program must not
   read stdin while such a child runs. (b) give the child `/dev/null` as stdin,
   and let the program choose a pipe later. **Recommendation:** (a), to match
   the script. The example does not read stdin.

   **Decided (2026-10-15):** the recommendation.

10. **Reaping orphans as PID 1.** Options: (a) document `docker run --init`. (b)
    make the VM reap orphans when it is PID 1, by calling `waitpid` on pids that
    libuv does not own. **Recommendation:** (a) now. The VM would need `waitpid`
    on pids it does not own, which is a separate decision.

    **Decided (2026-10-15):** the recommendation.

11. **Fallback when pidfd is unavailable.** Options: (a) refuse:
    `System.signal` returns `error("signal: pidfd is unavailable")`. (b) call
    `kill()` after the name check, which leaves a window in which a reused pid
    can be hit. The race is documented. **Recommendation:** (a). The window in
    (b) can signal a stranger. The gh-runner still ends after its deadline,
    because the group kill reaches a listener that stays in run.sh's group.

    **Decided (2026-10-15):** the recommendation.

12. **The name `Signal`.** Options: (A) keep `Signal.channel` and
    `Signal.number` beside the enum, and make `src/modules.rkt` resolve a
    function first. This is a front-end change in both front ends. (B) move the
    functions to `System.subscribe(signals)` and `System.signal_number(sig)`,
    and keep `Signal` as an enum only. **Recommendation:** (B). It avoids the
    `src/modules.rkt` clash. The enum parameter (no builtin takes one today) is
    checked with a spike in 46a. The fixture rename and the `**Breaking:**`
    entry happen under either option.

    **Decided (2026-10-15):** (B) is the starting point, not a final choice.
    The 46a PR makes the final choice between (A) and (B), as 46.3.1 and 46.7
    say.
