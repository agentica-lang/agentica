## 8. Concurrency and parallelism

Lightweight I/O tasks are implemented (phase 5j2). Their normative API lives in grammar.md: `Task.spawn` takes `Fn[A, R]` and one argument and returns `Task[R]`; `Task.await` returns `R`; `Task.sleep` takes nonnegative milliseconds. Channels are built (roadmap 17b) and specified in [section 27.2](27-iteration-and-concurrency.md#272-channels); `Task.map` (bounded concurrency over a list) is planned in [section 27.1](27-iteration-and-concurrency.md#271-taskmap). CPU parallelism remains a proposal: the VM is designed for multicore from its first tasks PR (`docs/vm/10-io-multicore.md` §10.2.3), but N>1 schedulers are gated, and the roadmap builds them only if the server measurement asks for it (roadmap order step 11). This section keeps only the open questions.

- Immutable values can be shared safely, but ports, sockets and contextual services are resources with state. They still need ownership or synchronization rules. A handle sent over a channel stays owned by the task that opened it.
- A diagnostic in a task other than `main` ends only that task (§37). `Result.error` remains a normal result.

### Future process polling

Process spawning may later expose a non-blocking helper:

```text
Process.poll_line(p: Process, timeout: Int) -> Result[String]
```

A loop can alternate between requests and polling with sync/timeout on child output. This is not part of the task phase.

### Open decisions

- Whether a concrete application needs `Process.poll_line` stays open.
- Whether measured CPU workloads justify parallel thread pools or places; default no. On the VM, CPU parallelism is the multicore schedulers (`docs/vm/10-io-multicore.md` §10.2.3, gated at roadmap order step 11), and `Task.map` (§27.1) is the form that would use it.
- A timeout on `Task.await` is planned in [section 27.3](27-iteration-and-concurrency.md#273-taskawait-with-a-timeout): `Task.await(task, timeout_ms) -> Result[T]`, prelude code over channels, which does not cancel the task.
- A public `Task.cancel` stays open: §27 cancels only the timed-out items of `Task.map`, and a cancel call would be a second way to stop work. Returning from the entrypoint still cancels pending work.
- Handles opened by a cancelled task stay open until the end of the run (§27.1). For long-running programs, such as servers, whether the VM should close them when the task is cancelled is open. Until then the skill teaches: open handles inside a `Task.map` item and close them with the block forms (`File.open` with a block, §25.9, once 15i lands; until then, `File.close` on every path), do not share handles across items, and give a shared handle to one owner task.

