---
title: Terminal
weight: 10
description: Whether a stream is a terminal, raw mode, the size of the terminal and its resize events.
---

A full-screen program (an editor, a TUI) reads keys one at a time and draws with VT escape sequences. `Terminal` gives what it needs from the system, the same on Linux, macOS and Windows 10 or later. Keys are still read with [`IO.read_bytes`](/library/io-and-system/io/) on standard input: they come as bytes, and the program (or its library) parses the escape sequences of the keys, the mouse and pasted text. The example waits for a key, so it shows a resize after the next key.

```agentica {mode="check"}
def main() -> Void
  Terminal.raw().unwrap!
  resized = System.subscribe([System.Signal.Winch]).unwrap!
  size = Terminal.size().unwrap!
  puts("#{size.rows}x#{size.cols}, q quits")
  IO.flush()
  while true
    if resized.recv(0).ok?
      size = Terminal.size().unwrap!
      puts("resized to #{size.rows}x#{size.cols}")
      IO.flush()
    end

    key = IO.read_bytes(1).unwrap!
    break if key.empty? or key.to_a == [113]
  end

  Terminal.raw(on: false).unwrap!
end
```

## Terminal.tty?

```signature
Terminal.tty?(stream: Terminal.Stream) -> Bool
```

Whether a standard stream is a terminal (on Windows, a console). `Terminal.Stream` is an enum: `Stdin`, `Stdout` and `Stderr`. A pipe, a file and `/dev/null` are not terminals.

```agentica
def main() -> Void
  puts(Terminal.tty?(Terminal.Stream.Stdout))
end
```

```output
false
```

## Terminal.raw

```signature
Terminal.raw(on: Bool = true) -> Result[Void]
```

Puts the terminal of standard input in raw mode, as Ruby's `IO#raw` does: what is typed is not shown, each key comes at once (no line editing, no wait for Enter), and the keys that send signals do not: Ctrl-C comes as the byte 3 and Ctrl-Z as 26. Output still goes on: `"\n"` starts a new line at the first column. `Terminal.raw(on: false)` gives back the mode the terminal had before the first `Terminal.raw`.

- On Windows it turns off line input, echo and the Ctrl-C event of the console, and turns on VT input (keys come as the same escape sequences as on Linux and macOS) and VT output.
- The VM gives the first mode back when the program ends: at its normal end, `System.exit`, a runtime error, a stop signal such as `Term` and an exit for lack of memory, so a crash of the program does not leave the shell in raw mode. A `kill -9` and a crash of the VM itself (`SIGSEGV`, `SIGBUS`) are not caught: run `stty sane` then.
- When standard input is not a terminal it returns an error with kind `io.failed` and the system's error number as its code. `Terminal.raw(on: false)` when raw mode is not on returns `ok`.
- The mode belongs to the terminal, not to a task: one call holds for every task.

```agentica
def main() -> Void
  case Terminal.raw()
    ok(_) -> puts("raw")
    error(e) -> puts(e.kind)
  end

  puts(Terminal.raw(on: false).ok?)
end
```

```output
io.failed
true
```

## Terminal.size

```signature
Terminal.size() -> Result[Terminal.Size]
```

The size of the terminal of standard output, or of standard error when standard output is not a terminal, as `Terminal.Size(rows: Int, cols: Int)`. On Windows it is the size of the console window. When neither stream is a terminal it returns an error with kind `io.failed`.

```agentica
def main() -> Void
  case Terminal.size()
    ok(size) -> puts("#{size.rows}x#{size.cols}")
    error(e) -> puts(e.kind)
  end
end
```

```output
io.failed
```

## Resize events

A resize of the terminal is the signal `System.Signal.Winch`, which [`System.subscribe`](/library/io-and-system/system/#systemsubscribe) delivers on a channel. Read the new size with `Terminal.size` when a value comes. Without a subscription a resize does nothing.

- On Linux and macOS it is `SIGWINCH`, which the system sends to the programs of the terminal's foreground job.
- On Windows the VM gets it when libuv sees the console change size; `Winch` is the one signal a Windows program can subscribe to.
