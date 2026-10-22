---
title: Waiting on a descriptor
weight: 4
description: Park a task until a C library's socket or descriptor can be read or written.
---

Many C network libraries (libpq, curl multi, hiredis) have a non-blocking mode: the library says which socket it waits for, and your program waits. `Native.wait_readable(fd, timeout_ms)` and `Native.wait_writable(fd, timeout_ms)` park the task until the descriptor can be read or written, while the other tasks go on. Both give a `Result[Void]`.

```agentica {mode="check"}
extern "libc.so.6"
  def eventfd(initval: C.Int, flags: C.Int) -> C.Int
  def eventfd_write(fd: C.Int, value: C.Int64) -> C.Int
end

def ring(fd: Int) -> Int
  Task.sleep(50)
  return eventfd_write(fd, 1)
end

def main() -> Void
  fd = eventfd(0, 0)
  bell = Task.spawn(&ring, fd)
  puts(Native.wait_readable(fd, 1_000))   # ok() once the other task writes
  puts(Task.await(bell))
end
```

A library's connect loop waits the same way, with `try Native.wait_readable(socket, 5_000)` between its polls.

- After `timeout_ms` (positive) the result is `error("native: timed out")`. A timeout that is not positive, a negative descriptor, and one that cannot be polled (closed, a regular file, `/dev/null`) give an error that starts with `native: `.
- An error or a hang-up on the descriptor ends the wait with `ok`, as `poll(2)` does: the library's next call reports it.
- The wait watches a new open of the descriptor's file, so the library keeps its descriptor and its flags, and two tasks may wait on one descriptor. A socket, or a file that cannot be opened again (an eventfd), is watched through a duplicate, which puts the descriptor in non-blocking mode.
- If the library closes the descriptor during a wait, the wait goes on and ends at its timeout (`native: timed out`) unless the file becomes ready.
- A cancel stops the wait; the end of the program does not wait for it.
- `--deny-native` refuses a program that calls them, as it refuses extern functions: a descriptor comes from native code.
