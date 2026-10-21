---
title: Concurrency
weight: 4
description: Run work at the same time with tasks, and pass values between tasks with channels.
---

Tasks are lightweight and share one VM scheduler. They overlap while they wait for I/O or a timer, but they do not run on several CPU cores. The tour page [Tasks](/tour/tasks/) is a short start.

- Use [Task](/library/concurrency/task/) to run work at the same time: start, await, pause and cancel tasks.
- Use a [Channel](/library/concurrency/channel/) to pass values between tasks. A producer sends and a consumer receives.
