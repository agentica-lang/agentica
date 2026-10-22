---
title: Compute calls
weight: 3
description: Run a long C call on the compute pool, so the other tasks keep running.
---

A function declared with `compute def` runs on the VM's compute pool, one thread per scheduler, and the calling task waits while the other tasks go on. Use it for a call that may take long: a query, a compression, a model step.

```agentica {mode="check"}
extern "libsqlite3.so.0"
  ## Sleeps for ms milliseconds off the scheduler.
  compute def sqlite3_sleep(ms: C.Int) -> C.Int
end

def main() -> Void
  sleeper = Task.spawn(&sqlite3_sleep, 200)
  puts("main goes on")
  puts(Task.await(sleeper))
end
```

- The result is the plain C value, as for `def`. Write `export compute def` to export one.
- Nothing stops a compute call in the middle: it has no timeout, and `--max-steps` does not end it. For a limit, run the call in a task and use `Task.await(task, ms)`. A cancel skips a call that has not started; a running call runs on, the cancelled task stops waiting at once, and the result is dropped. The program does not wait for a running call at the end.
- A call that never returns holds a pool thread for the rest of the run. Once `--schedulers` such calls are stuck, every later compute call waits.
- The arguments are copied before the call and a `C.String` result as it returns. The function runs on another thread, so it must be safe to call from one.
