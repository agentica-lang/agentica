## 46. Signals

**Status:** Scheduled on 2026-10-15 (row 7.8), after the bootstrap (§18, port
step 8, done). 46a and 46b may come earlier when no other VM PR is waiting.
Nothing is implemented yet.

The owner asked for a way to catch the OS stop signal in an Agentica program. A
container entrypoint should stop its child, run cleanup and exit with the right
code. The reference is a real launcher:
`/home/sonic182/apps/gh-runner/entrypoint.py`, a Python script that registers
and runs a GitHub Actions self-hosted runner. Section 46.4 is its Agentica
version.

### 46.1 Today

The VM has one stop path. A program cannot take part in it.

- **The stop path.** One `sigaction` handler covers SIGINT, SIGTERM and SIGHUP
  (`agc_io_watch_stop` in `vm/loop.c`), except a signal the VM started as
  ignored. It sets atomics and wakes the loop with `uv_async_send`; it never
  runs program code. The scheduler checks the first signal between turns
  (`check_stop` in `vm/task.c`), and the run ends as an exit with code 128 +
  signal (`agc_stop` in `vm/interp.c`). `agc_launch_settle` in `vm/launch.c`
  kills the children, flushes the output and the files, and raises the signal
  again with its default action. A second signal is only recorded until the
  children are stopped; a 3-second `alarm` (`STOP_GRACE_SECONDS` in `vm/loop.c`)
  bounds that wait. A driven VM whose driver is gone treats even the first
  signal as a second one. See `docs/vm/14-core-invariants.md` §14.4 and
  `docs/vm/10-io-scheduler.md` §10.2.2, "Stop signals".
- **No program view.** No builtin reports a signal, and no task ever sees one.
  The VM signals only the children it started (`uv_process_kill` in
  `signal_child`); it has no call to signal another pid or a process group.
- **Children.** `Process.spawn` and `Process.spawn_captured` leave the child in
  the VM's own process group and session. `Process.close` and the end of the run
  signal only the child's pid: SIGKILL for `spawn`; for `spawn_captured`
  SIGTERM, then SIGKILL one second later (`signal_child` and `shut` in
  `vm/process.c`). Descendants are not reached
  (`docs/grammar/06d-io-and-network.md`).
- **Exit status of a child.** `Process.wait` returns the exit code. A child
  killed by a signal returns 128 + signal (`finished` in `vm/process.c`). So a
  child that exits with 143 and a child killed by SIGTERM look the same.
- **Wait and stderr.** `Process.wait` returns when the child has exited and its
  stderr is at EOF (`docs/vm/10-io-processes.md`). A grandchild that keeps the
  stderr pipe open delays it. A timed-out wait returns `error("network:
  operation timed out")` and keeps the child (`agc_stream_timed_out`, defined in
  `vm/stream.c`).
- **libuv.** The VM has no `uv_signal_t` watcher for the stop signals
  (`docs/vm/15-layers.md`: `process.c` has no signal watchers). libuv has its
  own signal watcher inside `uv_spawn`, for SIGCHLD. A past VM hang came from a
  program that read the loop's own signal pipes. The guard is `private_pipe` in
  `vm/files.c`, from PR #162 (2026-10-13). Any new watcher must respect that
  guard and libuv's shared signal lock.
- **No driver delay.** An ordinary run is the process of the binary (since step
  8d-2), so a stop reaches the program at once.
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

The name `Signal` is a risk, and the 46a PR decides it, with this evidence. (1)
`tests/fixtures/vm/http-server-close.agc` has `struct Signal` (line 3). A user
type with a builtin name is `CHECK-REDEFINED-NAME`, so the reserved name is a
breaking change, and the fixture is renamed. (2) No builtin takes an enum as a
parameter today. `Await` is only a return value, and it has special checker code
(`check_await_timeout` in `compiler/check/check_collections.agc`).
`List[Signal]` as a parameter is new. (3) A builtin enum that shares its name
with a function namespace has no precedent. The module resolver
(`compiler/modules/resolve.agc`) reads `Name.x` as an enum constructor when
`Name` is a builtin enum. So `Signal.channel(...)` would be read as a
constructor. The options are: (A) keep `Signal.channel` and `Signal.number`, and
make the resolver resolve a function first, which is a front-end change; (B)
move them to `System.subscribe(signals)` and `System.signal_number(sig)`, and
keep `Signal` as an enum only. The recommendation is (B), which avoids the
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
- **The stop set.** `stop_signals[]` in `vm/loop.c` grows from INT, TERM and HUP
  to also USR1, USR2 and QUIT. `agc_io_block_stop` blocks the same list in
  worker threads, so these signals reach the loop thread, as the first three do.
  Without a subscription, USR1 and USR2 now take the stop path. The children
  stop, the output and the files are flushed, and the process dies by that
  signal, as TERM does. Today they end the process at once by their default
  action and leave the children running. This is a behavior change, and the 46a
  CHANGELOG entry says so.
- **Writes.** The handler has no `SA_RESTART`. A blocking write to stdout or
  stderr that a handled signal interrupts returns EINTR. Today `write_failed`
  (`vm/output.c`) treats EINTR as a stop only when a stop signal is set.
  Otherwise it reports `RUNTIME-INTERNAL`, which would fail the program on a
  handled TERM. 46a changes the callers. An EINTR write is retried for the rest
  of its bytes, after the stream's error flag is cleared. While a blocked stdout
  write is retried after EINTR, a handled signal waits until the write finishes;
  only a stop signal ends it.
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

Quit is never delivered. It always takes the stop path. The children stop, the
output and files are flushed as on any stop, and the process exits with status
131 by calling `_exit(131)`. It does not raise the signal again. So it leaves no
core dump, and a parent sees exit status 131, not death by a signal.
`agc_launch_settle` in `vm/launch.c` and the stop handler in `vm/loop.c`
special-case Quit this way. `_exit` is async-signal-safe, so the handler may
call it. A second Quit during that end takes the second-signal path, and it also
exits with 131.

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
- Windows would map Ctrl-C and Ctrl-Break to INT and TERM later. A
  Windows console has no POSIX process groups. Its group story would need a job
  object, as `docs/vm/08-loader-and-cli.md` plans. Not designed here.

#### 46.3.10 Tests and children

- A driven VM sets `PR_SET_PDEATHSIG` to SIGTERM (`agc_launch_bind` in
  `vm/launch.c`). When the driver dies, the VM gets SIGTERM. That signal is an
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
  `tests/test_vm_stop.py` checks (TERM, INT and HUP). USR1, USR2 and QUIT cases
  are new, in 46a.

#### 46.3.11 Layers

The first idea was a service on the loop thread, using the existing `uv_signal`
watchers. The code has no such watchers, so the placement changes
(`docs/vm/15-layers.md`).

- The stop state, the two masks, the handler and the subscription table stay in
  `vm/loop.c`, which is core. A service reaches the loop only through the port
  (`agc_io_uv`). The stop signals are not part of the port, so a service cannot
  touch the stop state.
- The channel offer goes in `vm/channel.c`, which is core. It is a send that
  never waits, with the one-value-per-signal rule and the end of the owning
  task. The `Signal.channel` builtin goes there too, next to the other Channel
  builtins.
- The EINTR retry for writes goes in the callers in `vm/output.c`, which is
  core.
- `Process.signal`, `Process.signal_group`, `Process.spawn_group`, the group
  close and `System.signal` go in `vm/process.c`. That file is a service. It may
  use libuv and plain syscalls, including the pidfd calls through `syscall()`.
- The builtin rows and the enum data go in `compiler/catalog/builtins_data.agc`
  (46.7).

No `uv_signal_t` watcher is added (46.3.2).

### 46.4 The entrypoint in Agentica

The program below is the `Supervisor` and the `main` flow of the gh-runner
script, in the proposed API. It does not compile today. `Signal`,
`Signal.channel`, `Signal.Term`, `Process.spawn_group`, `Process.signal_group`
and `System.signal` do not exist yet. The rest of the script is plain I/O and is
left out: the settings from the environment, the registration token request,
`config.sh` and `sudo chown` runs, the copy of the credential files and the
deregistration. It handles the URL and the runner name as Python does (a
trailing slash is stripped from `GITHUB_URL`, an empty `RUNNER_NAME` falls back
to the hostname), and differs from the script in three ways. Logging goes
through `std/logger`, which writes to stderr unless a handler is attached (the
stdout handler is in 46.5). The output of `config.sh` is captured and logged
after the process ends, not streamed. `sudo chown` runs every time, because
Agentica has no access check (46.5).

The mapping from Python is short. `handle_signal` becomes `first_signal`. It
returns the first value. Later values stay queued and unread, which is the
Python "ignore later signals" rule. The 1-second poll of `Popen.wait` becomes
`Task.await(finished, 1000)`, where `Await.TimedOut` is the tick. The timed-out
`Process.wait` is repeated inside `wait_exit`. The `STOP_TIMEOUT` deadline is
set in `begin_stop`. `os.killpg(pid, SIGKILL)` becomes `kill_group`. The
`os.kill` on each listener becomes `System.signal`.

```agentica
import Logger from "std/logger"

# Proposed API (46a, 46b): Signal, Signal.channel, Process.spawn_group,
# Process.signal_group and System.signal.

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

def launch() -> Result[Int]
  # Settings, preparation and configuration run here, as plain I/O.
  signals = try Signal.channel([Signal.Term, Signal.Int])
  no_args: List[String] = []
  Logger.info("starting run.sh")
  child = try Process.spawn_group(runner_dir() + "/run.sh", no_args, runner_dir(), 5000)
  run = try supervise(child, signals)
  if run.stopped
    # Deregistration runs here.
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
  arrives during deregistration is queued and ignored, as in the Python script.
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
- A signal during the preparation or configuration (before the subscription):
  Python has no handler yet, so a TERM kills it. This program takes the default
  path, which stops the `config.sh` child and then ends the process by that
  signal.

### 46.5 What the entrypoint needs, checked against today

Each need of the gh-runner script is checked against the builtins. "Partly"
means a workaround is possible; "missing" means the builtin or the module is not
there. The file-operation gaps are real, but they are not signal work, so they
go to their own change.

Missing, and in §46:

- **Stop signals TERM and INT:** `Signal.channel` with `Signal.Term` and
  `Signal.Int` (46.3.1).
- **Signal a child's group:** `Process.signal_group` (46.3.6).
- **Run run.sh as a session leader, with its output:** `Process.spawn_group`
  (46.3.6). It inherits the output, as Python does.
- **Signal a listener by pid:** `System.signal` through a pidfd (46.3.7).

Missing or partly, outside §46:

- **Run `./config.sh` in a directory (partly):** `spawn_captured` takes `dir`
  but captures stderr. `spawn` has no `dir`. The example captures config.sh and
  logs it.
- **Path exists check (partly):** `File.stat(path, t).ok?`. It follows symlinks
  and has no `exists?`.
- **Path copy that keeps the mode (missing):** `read_text` and `write_text` lose
  the mode and are text-only. Credential files need their mode. Proposed as
  `File.copy` (separate change).
- **Path writable check, `os.access` (missing):** the example runs `sudo chown`
  every time. A probe write is the workaround. Out of scope.
- **Hostname (missing):** no builtin. Use `HOSTNAME` (set by Docker) or
  `/etc/hostname`. A `System.hostname()` would be one row, if it is needed
  later. Out of scope.
- **Reap orphans as PID 1 (missing):** use `docker run --init`. Out of scope
  (46.8, question 10).

The rest exists: environment variables and boolean flags (`System.env`,
`String.trim`), spawning `sudo chown` (`Process.spawn_captured` with
`--allow-run`), the `/proc` scan (`Dir.list("/proc")` and `File.read_text`, not
yet tested on `/proc`), `Process.wait(p, ms)` with a deadline (it returns
`error("network: operation timed out")` and keeps the child, so the example
repeats the wait), `Path.remove` (a missing path is `ok`, a link is removed
itself, recursive and without following links, it refuses `/`, `.` and `..` and
trees deeper than 128 levels), `Dir.mkdir` (creates parents), `Dir.list` and
`File.lstat` (does not follow a link and gives `kind` `"link"`), `HTTP.post`
with TLS, the `JSON` calls, `Time.monotonic_ms()`, `System.exit(code)`, and
logging with timestamps to stdout (`Logger.attach` with a handler that calls
`IO.puts(Logger.format_text(event))`; the default handler writes to stderr, and
the time is UTC; `Logger.set_level` for `LOG_LEVEL`, with a few lines to parse
the name).

### 46.6 Testing plan (for later)

The tests are hermetic, Linux only, and follow the process-test rule of
`AGENTS.md`. They cover these behaviors:

- a handled TERM runs the cleanup, prints, and exits 0;
- a TERM is forwarded to a child started with `spawn_group`;
- a second TERM is ignored; QUIT exits with status 131 as a normal exit (not
  death by a signal), leaves no children, and writes no core file;
- a child that ignores TERM is killed with its group after the deadline;
- a signal to a pid carries the right name, and a wrong name is an error that
  leaves the process alive;
- INT is ignored at start, as `nohup` does: `Signal.channel` returns the
  `ignored` error, and INT stays ignored.

### 46.7 Phases

- **46a: subscription.** The `Signal` enum and its names (46.3.1). The option
  (A) or (B) of 46.3.1 is decided in this PR. The masks and the handler change
  in `vm/loop.c`, the stop set grows by USR1, USR2 and QUIT, and the EINTR retry
  goes in `vm/output.c` (46.3.2). Quit takes the `_exit(131)` path (46.3.3). The
  fixture `struct Signal` in `tests/fixtures/vm/http-server-close.agc` is
  renamed, since the reserved name collides with it. Tests: cases 1, 3 without
  the child, and 6 of 46.6. Docs: a Signals subsection in
  `docs/grammar/06c-tasks-and-tests.md`, the reserved name in
  `docs/grammar/04-lexical.md`, the site page, the programming skill, and a
  `CHANGELOG.md` entry under `## [Unreleased]`, marked `**Breaking:**` since
  `Signal` becomes a reserved builtin name, noting the USR1, USR2 and QUIT
  change.
- **46b: sending.** The builtins `Process.signal`, `Process.spawn_group`,
  `Process.signal_group` and `System.signal`, with the pidfd probe and
  `--allow-run`. The group close and the end-of-run group kill for group
  children. Tests: cases 2, 4 and 5 of 46.6. Docs:
  `docs/grammar/06d-io-and-network.md` (Processes), the site Process page, the
  programming skill's processes reference, `docs/vm/10-io-processes.md` §10.4
  and a `CHANGELOG.md` entry.
- **46c: the driver.** Obsolete as written: it forwarded a break at once from
  the Racket driver to a VM in its own process group (46.8, question 7). Since
  step 8d-2 an ordinary run is the process of the binary (46.1), so there is no
  driver to forward. A container runs `agentica` directly.
- **46d: graceful HTTP stop.** A drain in `std/http`: stop accepting, and wait
  for the handlers to finish, up to a deadline. It is a separate change in
  Agentica code, and it does not need the VM work of 46a or 46b in full. It
  comes after 46b by the owner's order.
- **Separate changes, outside §46:** `File.copy` that keeps the mode, and
  `System.hostname`. Reaping orphans as PID 1 is also separate (46.8, question
  10).

The compiler catalog (`compiler/catalog/builtins_data.agc`) is edited by hand in
the same PR as each builtin row, and its golden is refreshed with
`tools/refreeze.py`. Row 7.2.7 allows the table rows and the `vm-builtins`
names. The naming choice of 46.3.1 is the case that needs care, since option (A)
needs a front-end change.

### 46.8 Open questions

Each question has options and a recommendation. All were decided on 2026-10-15
as the recommendation, except question 12.

1. **API shape: channel or blocking wait.** Options: (a) `Signal.channel`, a
   subscription that queues values from the moment it is made. (b)
   `Signal.wait(names, timeout_ms)`, a blocking call. **Recommendation:** (a). A
   blocking call drops a signal that arrives before the call. It also needs a
   task for each wait point. The channel fits the timeouts that the programs
   already use.

2. **Names: enum or strings.** Options: (a) the builtin enum `Signal`. The
   checker catches a typo. The set is fixed by the VM. (b) strings, such as
   `Signal.channel(["TERM"])`, where a typo shows up only at run time.
   **Recommendation:** (a), as `LogLevel` does.

3. **Later signals.** Options: (A) as today: a second signal ends the run after
   the children are stopped, with the 3-second alarm. (B) the program decides:
   while a subscription exists, every Term, Int, Hup, Usr1 and Usr2 goes to the
   channel. Quit is the force path. It stops the children, flushes as on any
   stop, and exits 131 through `_exit`. (C) the program decides, but a repeat of
   the same signal within 3 seconds forces the exit. **Recommendation:** (B). It
   matches the gh-runner and Go's `signal.Notify`. The VM still never leaves a
   child behind, because Quit stops the children. The hard stop belongs to the
   parent: Docker's SIGKILL after 10 seconds, or `Process.close`. The cost is
   that a direct `agentica run`, with no parent to kill it, can only be stopped
   by Quit or SIGKILL. Ctrl-\ is less known than Ctrl-C twice, so the site page
   must say so. Option (C) is the fallback if the owner wants Ctrl-C twice to
   work.

4. **The grace alarm.** Options: (a) keep the 3-second alarm for the default
   path only. A handled signal never arms it. (b) a grace per subscription, such
   as `Signal.channel(signals, grace_ms)`. **Recommendation:** (a). A handled
   stop has no VM deadline. The program sets its own deadlines, as the example
   does.

5. **The permission flag.** Options: (a) no flag for subscribing. `--allow-run`
   for `spawn_group` and `System.signal`. (b) `--allow-run` for every signal
   call, including subscribing. (c) a new flag such as `--allow-signal`.
   **Recommendation:** (a). A program that subscribes only affects itself. A pid
   signal reaches other processes, so it belongs to the class that `--allow-run`
   already covers. A new flag adds one more thing to document for little gain.

6. **SIGHUP reload.** Options: (a) out of scope. HUP stays a stop signal only.
   (b) in scope as delivery only. HUP can be subscribed to, the VM does no
   reload, and the program decides. **Recommendation:** (b). It costs nothing
   once 46a exists, and the VM reloads nothing.

7. **The driver's 2-second wait.** Options: (a) keep it, and tell containers to
   run `agentica run` on the compiled file. (b) forward the break at once and
   drop the second copy that comes from the terminal. This is fragile. (c) start
   the VM in its own process group and forward the signal once.
   **Recommendation:** (a) now, and (c) in 46c, after a test with terminal
   input. Moot since step 8d-2: there is no Racket driver (46.7, 46c).

8. **The pid API shape.** Options: (a) `System.signal(pid, sig, comm)` with a
   pidfd and the name check. (b) `System.signal(pid, sig)` with no check, and a
   warning in the docs. (c) a handle from the scan, such as `Process.attach(pid,
   comm)`, returning a non-owning `Process`. **Recommendation:** (a). Option (b)
   is unsafe because of pid reuse. Option (c) makes `Process.close` dangerous,
   since it would kill a process the program does not own.

9. **Stdin of group children.** `spawn_group` children inherit stdin (46.3.6),
   as Python does. Options: (a) inherit, and document that the program must not
   read stdin while such a child runs. (b) give the child `/dev/null` as stdin,
   and let the program choose a pipe later. **Recommendation:** (a), to match
   the script. The example does not read stdin.

10. **Reaping orphans as PID 1.** Options: (a) document `docker run --init`. (b)
    make the VM reap orphans when it is PID 1, by calling `waitpid` on pids that
    libuv does not own. **Recommendation:** (a) now. The VM would need `waitpid`
    on pids it does not own, which is a separate decision.

11. **Fallback when pidfd is unavailable.** Options: (a) refuse:
    `System.signal` returns `error("signal: pidfd is unavailable")`. (b) call
    `kill()` after the name check, which leaves a window in which a reused pid
    can be hit. The race is documented. **Recommendation:** (a). The window in
    (b) can signal a stranger. The gh-runner still ends after its deadline,
    because the group kill reaches a listener that stays in run.sh's group.

12. **The name `Signal`.** Options: (A) keep `Signal.channel` and
    `Signal.number` beside the enum, and make the module resolver resolve a
    function first. This is a front-end change. (B) move the functions to
    `System.subscribe(signals)` and `System.signal_number(sig)`, and keep
    `Signal` as an enum only. **Recommendation:** (B). It avoids the resolver
    clash. The enum parameter (no builtin takes one today) is checked with a
    spike in 46a. The fixture rename and the `**Breaking:**` entry happen under
    either option.

    **Decided (2026-10-15):** (B) is the starting point, not a final choice.
    The 46a PR makes the final choice between (A) and (B), as 46.3.1 and 46.7
    say.

### 46.9 Implementation (row 7.8)

One PR per item, each with its own tests and docs. 46a subscription and 46b
sending are VM C code and may run earlier, when no other VM PR is waiting; 46d
(`std/http` drain) comes after 46b. Docs: the grammar (tasks, Processes,
reserved names), the site Process and Test pages, the programming skill,
`docs/vm/10-io-processes.md` §10.4, and CHANGELOG entries (46a breaking).

Done when: a program handles TERM, INT, HUP, USR1 and USR2 and stops its
children before it exits, with QUIT as the force path; it sends signals to its
own children and to a pid it did not start; `std/http` drains its handlers on a
stop; and the tests of §46.6 pass.
