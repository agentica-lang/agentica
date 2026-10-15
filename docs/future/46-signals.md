## 46. Signals

**Status:** Design, not scheduled (asked by the owner on 2026-10-15).

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
  stderr pipe open delays it.
- **Sending a signal.** The VM signals only the children it started
  (`uv_process_kill` in `signal_child`). It has no call to signal another pid,
  and no call to signal a process group.
- **libuv.** The VM has no `uv_signal_t` watcher for the stop signals.
  `docs/vm/15-layers.md` says that `process.c` has no signal watchers. libuv has
  its own signal watcher inside `uv_spawn`, for SIGCHLD. A past VM hang came
  from a program that read the loop's own signal pipes. The guard is
  `private_pipe` in `vm/files.c`, from PR #162 (2026-10-13). Any new watcher
  must respect that guard and libuv's shared signal lock.
- **The driver.** `agentica file.agc` runs the VM under a Racket driver
  (`src/main.rkt`, `src/vm-launch.rkt`). The driver handles SIGINT, SIGTERM and
  SIGHUP as Racket breaks (`call-noting-break`). On a break it waits up to 2
  seconds for the VM. Then it sends SIGTERM, waits 2 more seconds, and sends
  SIGKILL (`stop-vm`). If the driver is PID 1 in a container, the VM gets its
  first signal 2 seconds after the stop. A handled stop then has about 2 seconds
  to finish.
- **A direct run.** `agentica compile FILE.agc -o FILE.agcb` writes bytecode.
  `agentica-vm [--allow-run] -- FILE.agcb` runs it with no driver (usage in
  `vm/main.c`, and `docs/vm/08-loader-and-cli.md` §9). A container can use this
  path today. The stop reaches the program at once.
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
(`src/builtin-types.rkt`). Its variants are `Signal.TERM`, `Signal.INT`,
`Signal.HUP`, `Signal.USR1`, `Signal.USR2`, `Signal.QUIT` and `Signal.KILL`.

- The first five can be subscribed to. `QUIT` is the VM's force path (46.3.3),
  so a program cannot take it. `KILL` cannot be caught by any program.
  Subscribing to `QUIT` or `KILL` is a runtime error at the argument,
  `RUNTIME-INVALID-SIGNAL`.
- The channel keeps at most one pending value per signal. Its capacity is five,
  which is the number of subscribable signals. A second TERM that arrives while
  one TERM is pending is not queued again. So nothing is dropped, and nothing
  blocks in the loop. The cost is that counts are lost. A program that needs
  every press must use another design.
- `Signal.number(Signal.TERM)` is 15 on Linux. It lets a program write
  `System.exit(128 + Signal.number(Signal.TERM))`.

The channel is better than `Signal.wait(names, timeout_ms)`. A blocking wait
drops a signal that arrives before the call. A subscription queues the signal
from the moment the program subscribes. The channel also fits the timeouts that
the programs already use with `Channel.recv` and `Task.await`. The
recommendation is in 46.8, question 1.

#### 46.3.2 Ownership and the default action

- The subscription belongs to the task that opened it, like any handle
  (`docs/grammar/06c-tasks-and-tests.md`). It ends when that task ends in any
  way: return, crash or cancel. It also ends when the program calls
  `Channel.close` on the channel.
- When the last subscription to a signal ends, the default action comes back at
  once. From then on the VM's own stop handler runs for that signal.
- While a subscription exists, the signal does not start the VM's stop path. It
  is queued on the channel, and nothing else happens. This is the only change to
  the first-signal rule of 46.1. A signal that several subscriptions want goes
  to each of them.
- A driven VM whose driver is gone does not deliver the signal. It takes the
  default path, as in 46.1, because no driver is left to wait for. This also
  covers the `PR_SET_PDEATHSIG` signal (46.3.10).

The VM keeps the pending state in an atomic mask, one bit per signal number. The
handler sets the bit and wakes the loop with the `uv_async_send` that it already
uses. The loop then offers the signal to each subscription with a send that
never waits. This adds no second signal mechanism. A `uv_signal_t` watcher was
considered and rejected. libuv's signal watchers share a lock and a pipe (46.1),
and libuv puts back the default action when it stops the last watcher of a
signal. The VM would then have to restore its own handler each time. A test
would need to confirm the second point.

#### 46.3.3 Later signals

The gh-runner ignores every signal after the first. Today the VM exits on a
second signal, after the children are stopped (46.1). The choice is open. The
recommendation is to deliver every signal on the channel while a subscription
exists, and to keep `QUIT` as the force path. The options are in 46.8, question
3.

Under the recommendation, `QUIT` stops the children and exits as soon as they
are stopped. It goes through the VM's stop path, not through the default action,
so no child is left running. This needs a VM change. Today the VM does not
handle QUIT, and its default action dumps core and leaves the children running.
So QUIT joins the stop set in 46a.

A program that ignores later signals can still be stopped by `QUIT` (Ctrl-\) or
by its parent's SIGKILL.

#### 46.3.4 The grace alarm

`STOP_GRACE_SECONDS` bounds only the default path, meaning a second default stop
while the children are being stopped. A handled signal never enters that path,
so the alarm is never armed for it. A program that handles TERM and needs ten
seconds of cleanup is not cut by the alarm.

The alarm can still cut a program on its default path. An example is a `QUIT`
that arrives while the children are being stopped.

The parent's SIGKILL is a different thing. It is the parent's timer, as
`STOP_TIMEOUT` is in the gh-runner script. The VM does not add a deadline for a
handled stop. The program sets its own deadline, as the example does.

#### 46.3.5 Sending to a child

```text
Process.signal(p: Process, sig: Signal) -> Result[Void]
```

This sends the signal to the child's pid. An exited or closed child gives an
error Result. The rule for `Process.wait` does not change, so it still returns
128 + signal for a child killed by a signal.

No change to `Process.wait` is needed for the use cases here. The gh-runner
returns 0 after its own stop, and the run.sh code otherwise. If a program ever
needs to tell a signal death from an exit code, the smallest change is a builtin
that returns the signal number. It is not proposed now.

#### 46.3.6 Process groups

```text
Process.spawn_group(command: String, args: List[String], dir: String, timeout_ms: Int) -> Result[Process]
Process.signal_group(p: Process, sig: Signal) -> Result[Void]
```

- `spawn_group` is `spawn` with two changes. The child gets a new session
  (`setsid`), so its pid is the group id, as `start_new_session=True` does in
  Python. The child also takes `dir`, as in `spawn_captured`. The stream rules
  are those of `spawn`: stdout is read with `read_line` and `read_bytes`, and
  stderr goes to the program's stderr. The command still resolves against the
  program's working directory, not `dir` (`docs/grammar/06d-io-and-network.md`).
  So the example uses an absolute path.
- `signal_group` sends the signal to the whole group (`kill(-pid, sig)`). It is
  an error for a child that was not made by `spawn_group`. It is also an error
  once the leader has been reaped. The VM knows that from its own state. While
  the leader exists, its pid cannot be reused, so the group id is safe. After
  the leader is reaped the group may still have members. The VM does not guess
  in that case, and it refuses.
- `Process.close` and the end of the run send to the whole group for a
  `spawn_group` child. They send SIGKILL, or SIGTERM and then SIGKILL for a
  captured child. Other children are unchanged. This closes the "descendants are
  not covered" limit for group children only.
- `Process.wait` on a group child returns when the leader exits, not when stderr
  reaches EOF. Later stderr is still forwarded until EOF or until the end of the
  run. Without this change, a grandchild that outlives its leader would block
  `wait` (46.1). The recommendation is in 46.8, question 9.

#### 46.3.7 Signals to a pid that is not a child

```text
System.signal(pid: Int, sig: Signal, comm: String) -> Result[Void]
```

The gh-runner finds `Runner.Listener` by scanning `/proc/*/comm`. Then it sends
the listener SIGTERM. The listener is not a child of the program. It is a
grandchild, under run.sh. The scan is possible today with `Dir.list("/proc")`
and `File.read_text`. The signal is not possible today. There are three ways to
make it work.

- **(a) Signal the run.sh group.** This is not the same. The group may also hold
  the job worker, which would then get TERM too. This changes what the runner
  does, so it is rejected.
- **(b) `System.signal(pid, sig)` with no check.** This is unsafe. A pid read
  from a scan can be reused by another process before the signal is sent. The
  program would then signal a stranger. This is rejected.
- **(c) `System.signal(pid, sig, comm)` with a pidfd.** This is proposed. The VM
  opens a pidfd for the pid with `pidfd_open` (Linux 5.3 or later). While a
  pidfd is open, the kernel does not reuse its pid number. So the VM reads
  `/proc/<pid>/comm` through the same process and compares it with `comm`. If
  the names match, the VM sends the signal with `pidfd_send_signal`. The check
  and the signal then refer to one process. If the names differ, the call
  returns an error.

The rules for (c) are these.

- `comm` is required. The kernel keeps 15 bytes of the name, and the comparison
  uses that form. `Runner.Listener` is exactly 15 bytes.
- A pid of zero or less is an error. The VM's own pid is an error too, so that a
  program cannot signal itself by mistake.
- On a kernel without pidfd (before 5.3) the call returns `signal: pidfd is
  unavailable`. It never falls back to a plain `kill` with a check, because the
  check and the kill would race.
- The kernel checks the user. A process of another user gives the permission
  error.

The VM guarantees which process gets the signal. It does not guarantee that the
program chose the right one. A program that matches the wrong name still signals
the wrong process. The permission for this call is in 46.3.8.

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

- Linux first. SIGKILL cannot be caught or blocked, so `Signal.KILL` is a value
  to send, never one to receive. SIGSTOP is not in the enum.
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
  `tests/test_vm_stop.py` checks.

#### 46.3.11 Layers

The first idea was a service on the loop thread, using the existing `uv_signal`
watchers. The code has no such watchers, so the placement changes
(`docs/vm/15-layers.md`).

- The stop state and the handler stay in `vm/loop.c`. That file is core. The
  subscription table and the pending mask go there too. A service reaches the
  loop only through the port (`agc_io_uv`). The stop signals are not part of the
  port, so a service cannot touch the stop state.
- The channel offer goes in `vm/channel.c`, which is core. That is a send that
  never waits, with the one-per-signal rule and the end of the owning task. The
  `Signal.channel` builtin goes there too, next to the other Channel builtins.
- `Process.signal`, `Process.signal_group`, `Process.spawn_group`, the group
  close and `System.signal` go in `vm/process.c`. That file is a service. It may
  use libuv and plain syscalls.
- The builtin rows go in `src/builtins.rkt`, the enum goes in
  `src/builtin-types.rkt`, and the `vm-builtins` names follow. Row 7.2.7 of the
  roadmap allows those rows. The compiler port in `compiler/` gets the same rows
  when its builtin catalog is written.

No `uv_signal_t` watcher is added (46.3.2).

### 46.4 The entrypoint in Agentica

The program below is the `Supervisor` and the `main` flow of the gh-runner
script, in the proposed API. It does not compile today. `Signal`,
`Signal.channel`, `Signal.number`, `Process.spawn_group`,
`Process.signal_group`, `System.signal`, `Path.remove` and `File.copy` do not
exist yet. Constants are functions until module constants (§44) land.

The mapping from Python is short. `handle_signal` becomes `first_signal`. It
returns the first value, and later values stay queued and unread, which is the
Python "ignore later signals" rule. The 1-second `wait` poll becomes
`Task.await(finished, 1000)`, where `Await.TimedOut` is the tick. The
`STOP_TIMEOUT` deadline is set in `begin_stop`. `os.killpg(pid, SIGKILL)`
becomes `kill_group`. The `os.kill` on each listener becomes `System.signal`.
`deregister` and `fetch_token` keep their rules.

```agentica
import HTTP from "std/http"
import Logger from "std/logger"

# Proposed API: Signal, Signal.channel, Signal.number, Process.spawn_group,
# Process.signal_group, System.signal, Path.remove and File.copy.
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

def day_ms() -> Int
  # Process.wait and Channel.recv need a positive timeout. A day means no limit.
  return 86400000
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

def settings() -> Result[Settings]
  url = env_or("GITHUB_URL", "").trim
  if !url.starts_with?("https://github.com/")
    return error("GITHUB_URL must be https://github.com/OWNER or https://github.com/OWNER/REPO")
  end
  ephemeral = env_flag("RUNNER_EPHEMERAL", true)
  return ok(Settings(url: url, pat: env_or("GITHUB_PAT", ""), token: env_or("RUNNER_TOKEN", ""), name: env_or("RUNNER_NAME", env_or("HOSTNAME", "runner")), labels: env_or("RUNNER_LABELS", ""), group: env_or("RUNNER_GROUP", ""), work: env_or("RUNNER_WORKDIR", "_work"), state_dir: env_or("STATE_DIR", "/home/runner/state"), ephemeral: ephemeral, deregister: env_flag("RUNNER_DEREGISTER_ON_STOP", ephemeral)))
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
  headers = [Header(name: "Accept", value: "application/vnd.github+json"), Header(name: "Authorization", value: "Bearer #{config.pat}"), Header(name: "X-GitHub-Api-Version", value: "2022-11-28")]
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
  args: List[String] = ["--unattended", "--replace", "--url", config.url, "--token", token, "--name", config.name, "--work", config.work]
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
        case System.signal(pid, Signal.TERM, "Runner.Listener")
          ok(_) -> Logger.info("signal sent")
          error(message) -> Logger.err(message)
        end
      end
  end
end

## Waits for the first stop signal. Later signals stay queued and are never read.
def first_signal(signals: Channel[Signal]) -> Result[Signal]
  return signals.recv(day_ms())
end

## Returns the stop deadline in monotonic milliseconds, or 0 while the runner runs.
## The first signal stops the listeners once and starts the deadline.
def begin_stop(first: Task[Result[Signal]], deadline: Int) -> Int
  if deadline > 0
    return deadline
  end
  case Task.await(first, 1)
    Await.Done(_) ->
      stop_listeners()
      return Time.monotonic_ms() + stop_timeout_ms()
    Await.TimedOut -> return 0
  end
end

def wait_exit(child: Process) -> Result[Int]
  return Process.wait(child, day_ms())
end

def kill_group(child: Process) -> Void
  case Process.signal_group(child, Signal.KILL)
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
  signals = try Signal.channel([Signal.TERM, Signal.INT])
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
  before `Popen`. The subscription lasts until `main` ends. So a TERM that
  arrives during `deregister` is queued and ignored, as in the Python script. A
  signal during `prepare` or `configure` takes the default path, which stops the
  `config.sh` child and exits. In Python that case kills the process.
- The exit code follows the gh-runner script. After its own stop, the program
  exits 0. Otherwise it exits with the run.sh code. A runner that follows the
  shell pattern exits with 128 + N. That is one line: `System.exit(128 +
  Signal.number(Signal.TERM))`.
- The stop is slower than in Python. Python signals the listeners inside the
  handler. This program signals them on the next tick, at most one second later.
  A shorter tick costs more wake-ups. The tick can be set to 100 ms if the owner
  needs it.
- Each `case` on a `Result` lists both arms. Each `Await` is matched by name.
  The file has no `break if x`, no `elif`, and no `when`.

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
| Stop signals TERM and INT | missing | `Signal.channel` (46.3.1) |
| Signal a child's group | missing | `Process.signal_group` (46.3.6) |
| Run run.sh as a session leader | missing | `Process.spawn_group` (46.3.6) |
| Run `./config.sh` in a directory | partly | `spawn_captured` takes `dir` but hides stderr. `spawn` has no `dir`. The example uses an absolute path. `spawn_group` fixes both. |
| Spawn `sudo chown` | exists | `Process.spawn_captured` with `--allow-run`. sudo must be present. |
| Scan `/proc` for Runner.Listener | exists | `Dir.list("/proc")` and `File.read_text`. Not yet tested on `/proc`. |
| Signal a listener by pid | missing | `System.signal` with a pidfd (46.3.7) |
| Wait for exit with a deadline | exists | `Process.wait(p, ms)`. Group children get a change (46.3.6). |
| Path: exists check | partly | `File.stat(path, t).ok?`. It follows symlinks and has no `exists?`. |
| Path: unlink | missing | Proposed as `Path.remove` (separate change). |
| Path: rmtree | missing | `Path.remove` covers it, recursively and without following links. |
| Path: copy2 that keeps the mode | missing | `read_text` and `write_text` lose the mode and are text-only. Credential files need their mode. Proposed as `File.copy` (separate change). |
| Path: mkdir -p | exists | `Dir.mkdir` creates parents. |
| Path: iterdir with is_dir and is_symlink | partly | `Dir.list` gives names. `File.stat` follows links, so a link is not seen as a link. |
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
   handles TERM by writing a marker and exiting 0. On TERM the program forwards
   the signal with `Process.signal`. The test checks the marker and the exit
   code.
3. **Later signals and the force path.** The program ignores a second TERM and
   keeps running. The test sends a second TERM and checks that the program is
   still alive. Then it sends QUIT. The test checks that the program exits, that
   its children are gone (`os.killpg` with signal 0 fails), and that the exit
   code is 131.
4. **Escalation.** A child ignores TERM. The program sends KILL to the group
   after its deadline. The test checks that the group is gone.
5. **Pid signals.** A test-owned process is started from a symlink named
   `signal-target` to `/bin/sleep`, so that its comm is that name. The program
   signals it with `System.signal` and the right name, and the signal arrives.
   With a wrong name, the call returns an error and the process is still alive.

The C side is tested in `vm/tests` with `make vm-test`. The tests cover the
pending mask, the one-per-signal rule of the channel, the end of the owning task
and the fan-out to several subscriptions. The existing `tests/test_vm_stop.py`
keeps checking programs without a subscription. Those are the default-path
cases.

### 46.7 Phases

- **46a: subscription.** The `Signal` enum and `Signal.channel`,
  `Signal.number`. The pending mask and the handler change in `vm/loop.c`. The
  channel offer and the end of the owning task in `vm/channel.c`. QUIT joins the
  stop set as the force path. The C and Python tests from 46.6. The docs: a new
  subsection in `docs/grammar/06c-tasks-and-tests.md`, the reserved name in
  `docs/grammar/04-lexical.md`, the site page, the programming skill, and a
  `CHANGELOG.md` entry under `## [Unreleased]`. The QUIT change is user-visible.
  It is not breaking, since QUIT used to dump core and now stops the run
  cleanly, and the entry says so.
- **46b: sending.** `Process.signal`, `Process.spawn_group`,
  `Process.signal_group`, the group close and the end-of-run kill for group
  children, `wait` at exit for group children, and `System.signal` with pidfd
  and `--allow-run`. The tests from 46.6, cases 2 to 5.
- **46c: the driver.** The driver forwards a break at once to a VM in its own
  process group (46.8, question 7). It needs a test with terminal input first.
  Until then, containers use `agentica compile` and `agentica-vm` directly
  (46.1). That recipe belongs in the site page.
- **46d: graceful HTTP stop.** A drain in `std/http`: stop accepting, and wait
  for the handlers to finish, up to a deadline. It is a separate change in
  Agentica code, and it does not need the VM work of 46a or 46b in full.
- **Separate changes, outside §46:** `Path.remove`, `File.copy` that keeps the
  mode, a kind check that does not follow links, and `System.hostname`. Reaping
  orphans as PID 1 is also separate (46.8, question 10).

The bootstrap question. 46a and 46b can land before the bootstrap. Their parts
are VM code and builtin table rows, which row 7.2.7 allows. They need no new
syntax and no new checker rule. The `LogLevel` enum is data in
`src/builtin-types.rkt`, and `Signal` should be the same kind of data. If it
needs checker support, that is a separate decision. The rows must also reach the
compiler catalog in `compiler/` before the bootstrap, because §35 says a builtin
change goes to both front ends. 46c depends on nothing else. 46d is Agentica
code and can come after the bootstrap.

### 46.8 Open questions

Each question has options and a recommendation.

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
   while a subscription exists, every signal goes to the channel, and `QUIT` is
   the force path, which stops the children and exits as soon as they are
   stopped. (C) the program
   decides, but a repeat of the same signal within 3 seconds forces the exit.
   **Recommendation:** (B). It matches the gh-runner and Go's `signal.Notify`.
   The VM still never leaves a child behind, because `QUIT` stops the children.
   The hard stop belongs to the parent: Docker's SIGKILL after 10 seconds, the
   driver's SIGKILL, or `Process.close`. The cost is that a program that never
   reads its channel can only be stopped by `QUIT` or SIGKILL. Ctrl-\ is less
   known than Ctrl-C twice, so the site page must say so. Option (C) is the
   fallback if the owner wants Ctrl-C twice to work.
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
   run `agentica-vm` on the compiled file. (b) forward the break at once and
   drop the second copy that comes from the terminal. This is fragile. (c) start
   the VM in its own process group and forward the signal once. Under Ctrl-C the
   terminal reaches only the driver, which forwards one copy. A signal from
   Docker reaches the driver, which also forwards it. **Recommendation:** (a)
   now, and (c) in 46c, after a test with terminal input.
8. **The pid API shape.** Options: (a) `System.signal(pid, sig, comm)` with
   pidfd and the name check. (b) `System.signal(pid, sig)` with no check, and a
   warning in the docs. (c) a handle from the scan, such as `Process.attach(pid,
   comm)`, returning a non-owning `Process`. **Recommendation:** (a). Option (b)
   is unsafe because of pid reuse. Option (c) makes `Process.close` dangerous,
   since it would kill a process the program does not own.
9. **Wait for group children.** Options: (a) `wait` returns when the leader
   exits. Later stderr is forwarded until EOF or the end of the run. (b) keep
   the current rule, where `wait` returns at stderr EOF. **Recommendation:**
   (a), for `spawn_group` children only. Other children keep the current rule.
10. **Reaping orphans as PID 1.** Options: (a) document `docker run --init`. (b)
    make the VM reap orphans when it is PID 1, by calling `waitpid` on pids that
    libuv does not own. **Recommendation:** (a) now. The VM would need `waitpid`
    on pids it does not own, which is a separate decision.
