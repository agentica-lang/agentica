---
title: Concurrency
weight: 4
description: Run work at the same time with tasks, and pass values between tasks with channels.
---

Tasks are lightweight and share one VM scheduler, so they overlap while they wait for I/O or a timer. They do not run on several CPU cores. The tour page [Tasks](/tour/tasks/) is a short start.

- Use [Task](/library/concurrency/task/) to run work concurrently: `Task.spawn` starts a function in a new task, and `Task.await` waits for its result. `Task.sleep` pauses a task.
- Use a [Channel](/library/concurrency/channel/) when tasks must pass values to each other. A producer sends and a consumer receives, which gives a pipeline. To merge several sources (fan-in), send them all into one channel of an enum type.
- Timeouts: `Channel.send` and `Channel.recv` take a timeout in milliseconds and give an `error` when it runs out, so a task never waits forever.
