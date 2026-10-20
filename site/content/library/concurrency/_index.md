---
title: Concurrency
weight: 4
description: Run work at the same time with tasks, and pass values between tasks with channels.
---

Tasks are lightweight and share one VM scheduler. They overlap while they wait for I/O or a timer, but they do not run on several CPU cores. The tour page [Tasks](/tour/tasks/) is a short start.

- Use [Task](/library/concurrency/task/) to run work at the same time. `Task.spawn` starts a function, and `Task.await` waits for its result. `Task.await(task, timeout_ms)` gives an `Await`: `Await.Done(value)` or `Await.TimedOut`. `Task.spawn_owning` also gives a file, socket, listener or process to the new task, which closes it when it ends. `Task.sleep` pauses a task, and `Task.cancel` stops one you no longer need.
- Use a [Channel](/library/concurrency/channel/) to pass values between tasks. A producer sends and a consumer receives. To merge several sources, send them all into one channel of an enum type.
- Channel calls take a timeout in milliseconds. When it runs out, they give an `error`, so a task never waits forever.
