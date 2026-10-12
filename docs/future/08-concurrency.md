## 8. Concurrency and parallelism

Lightweight I/O tasks are implemented before networking in phase 5j2. Their normative API lives in grammar.md: Task.spawn takes Fn[A, R] and one argument and returns Task[R]; Task.await returns R; Task.sleep takes nonnegative milliseconds. Channels and `Task.map` (bounded concurrency over a list) are planned in [section 27](27-iteration-and-concurrency.md#27-iteration-and-concurrent-collections) (roadmap phase 17); CPU parallelism remains a proposal. Supporting multiple connections is the concrete reason to prepare evaluator isolation before TCP and HTTP.

### Racket building blocks

| Tool | Module | Parallel? | Notes |
|---|---|---|---|
| Green threads, channels, `sync`, semaphores | `racket/base` | One core | Cheapest; enough for I/O concurrency; no new dependency |
| Parallel threads, `thread #:pool` | `racket/base` | Multicore on supported CS builds | Available since 8.18.0.2; synchronization costs need measurement |
| Places, `place-channel` | `racket/place` | Real multicore | One VM per place; messages serialized; heavy |
| Futures | `racket/future` | Limited | Parallel only for a safe value subset; finicky performance; not proposed |

The implementation uses ordinary coroutine threads. Racket CS 9.3 also supports parallel thread pools; places are not the only multicore option. See [Racket threads](https://docs.racket-lang.org/reference/threads.html). In the evaluator, add CPU parallelism only after measuring a concrete workload and reviewing shared state. The VM is designed for multicore from its first tasks PR (`docs/vm/10-io-multicore.md` §10.2.3), but N>1 schedulers are gated: the roadmap builds them only if the server measurement asks for it (roadmap order step 11).

### Shape: builtin modules, no grammar change

Task is a builtin module over Racket primitives using function values (5j) and a generic opaque result type, with no new keywords. The channel proposal that stood here (`Channel.new()`, `send` returning `Void`, `recv` returning `T`) is replaced by the final design of [section 27.2](27-iteration-and-concurrency.md#272-channels): a bounded `Channel[T]` with `new(capacity)`, `send` and `recv` that take a timeout and return a `Result`, `close` and `closed?`. Its buffering, close, timeout and cancellation rules are decided there together, as this section asked, with the task cancellation of `Task.map` ([section 27.1](27-iteration-and-concurrency.md#271-taskmap)).

- Task inputs travel through one argument and results through Task.await; channels (§27.2) provide repeated exchanges.
- Immutable values can be shared safely, but ports, future sockets and contextual services are resources with state. They still need ownership or synchronization rules.
- Task diagnostics already terminate the whole evaluation, even when unawaited; Result.error remains a normal result.

### Future process polling

Process spawning may later expose a non-blocking helper:

```text
Process.poll_line(p: Process, timeout: Int) -> Result[String]
```

A loop can alternate between requests and polling with sync/timeout on child output. This is not part of the task phase.

### Implemented evaluator isolation

The evaluator prepares immutable function/struct tables once per evaluation, then creates independent scopes, depth, returns and diagnostic escapes for each task. src/task.rkt owns supervision, cached results and the synchronized global step budget. A run custodian cancels pending tasks and closes new resources at completion or interruption; borrowed ports remain open. BDD rejects pending tasks on handler return and keeps scenario continuation.

### Open decisions

- Channels are decided (§27.2). Whether a concrete application needs Process.poll_line stays open.
- Whether measured CPU workloads justify parallel thread pools or places; default no. On the VM, CPU parallelism is the multicore schedulers (`docs/vm/10-io-multicore.md` §10.2.3, gated at roadmap order step 11), and `Task.map` (§27.1) is the form that would use it.
- A public `Task.cancel` and a timeout on `Task.await` stay open: §27 adds only the per-item timeout of `Task.map` and the timeouts of channel calls, and each new form would be a second way to stop or wait for work. Returning from the entrypoint still cancels pending work.

