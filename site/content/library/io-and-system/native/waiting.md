---
title: Waiting on a descriptor
weight: 4
description: Park a task until a C library's socket or descriptor can be read or written.
---

Many C network libraries (libpq, curl multi, hiredis) have a non-blocking mode: the library says which socket it waits for, and your program waits. `Native.wait_readable(fd, timeout_ms)` and `Native.wait_writable(fd, timeout_ms)` park the task until the descriptor can be read or written, while the other tasks go on. Both give a `Result[Void]`.

```agentica {mode="check"}
extern "libc.so.6"
  def eventfd(initval: C.Int32, flags: C.Int32) -> C.Int32
  def eventfd_write(fd: C.Int32, value: C.Int64) -> C.Int32
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

- After `timeout_ms` (positive) the result is `error("native: timed out")`. A timeout that is not positive, a negative descriptor, and one that cannot be polled (closed, a regular file, `/dev/null` on Linux) give an error that starts with `native: `. On macOS `/dev/null` is always ready.
- An error or a hang-up on the descriptor ends the wait with `ok`, as `poll(2)` does: the library's next call reports it.
- The wait watches a copy of the descriptor (a new open of its file, `/proc/self/fd` or `F_GETPATH` on macOS, or a duplicate for a socket, a terminal master, an eventfd and a macOS pipe), so the library keeps its descriptor and its flags, and two tasks may wait on one descriptor.
- If the library closes the descriptor during a wait, the wait goes on and ends at its timeout (`native: timed out`) unless the file becomes ready.
- A cancel stops the wait; the end of the program does not wait for it.
- On Windows only a socket can be waited on: the number is the library's Winsock `SOCKET`, watched through a duplicate socket. That puts the socket in non-blocking mode for good, since Winsock cannot read the mode back. One socket handle takes one wait at a time: a second wait on the same handle value while one is waiting gives an error that starts with `native: `, and the value of a closed socket may stay busy until its wait ends. Any other value (a C runtime descriptor, a file or pipe handle) gives such an error too, and so does a closed socket, usually (Windows reuses handle values).
- `--deny-native` refuses them too: a descriptor comes from native code.
