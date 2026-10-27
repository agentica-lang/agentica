---
title: Concurrency
weight: 4
description: Run work at the same time with tasks, pass values between tasks with channels, and share state in ATS tables.
---

Tasks are lightweight and run on the VM's schedulers, one per logical core by default, so they use several CPU cores and overlap while they wait for I/O or a timer. Their order is not fixed; `--schedulers 1` runs one task at a time. The tour page [Tasks](/tour/tasks/) is a short start.

- Use [Task](/library/concurrency/task/) to run work at the same time: start, await, pause and cancel tasks.
- Use a [Channel](/library/concurrency/channel/) to pass values between tasks. A producer sends and a consumer receives.
- Use an [ATS](/library/concurrency/ats/) table to share a counter or a cache that tasks update in place.
