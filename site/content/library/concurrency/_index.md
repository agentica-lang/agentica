---
title: Concurrency
weight: 4
description: Run work at the same time with tasks, and pass values between tasks with channels.
---

Tasks are lightweight and run on the VM's schedulers, one per logical core by default, so they use several CPU cores and overlap while they wait for I/O or a timer. Their order is not fixed; `--schedulers 1` runs one task at a time. The tour page [Tasks](/tour/tasks/) is a short start.

- Use [Task](/library/concurrency/task/) to run work at the same time. `Task.spawn` starts a function, and `Task.await` waits for its result. `Task.await(task, timeout_ms)` gives an `Await`: `Await.Done(value)` or `Await.TimedOut`. `Task.spawn_owning` also gives a file, socket, listener or process to the new task, which closes it when it ends. `Task.sleep` pauses a task, and `Task.cancel` stops one you no longer need.
- Use a [Channel](/library/concurrency/channel/) to pass values between tasks. A producer sends and a consumer receives. To merge several sources, send them all into one channel of an enum type.
- Channel calls take a timeout in milliseconds. When it runs out, they give an `error`, so a task never waits forever.
