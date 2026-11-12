---
title: Error
weight: 2
description: The record a failed Result holds.
---

A failed `Result` holds an `Error`, a builtin record. `error("text")` builds one, `error("text", kind: "db.constraint", code: 19)` sets more of its fields, and the pattern `error(e)` binds it.

```text
struct Error
  kind: String = "error"
  message: String
  code: Optional[Int] = none
  details: Map[String, String] = {}
  cause: Optional[Error] = none
  location: String = ""
end
```

- `kind` is a dotted name for the sort of failure; `error("text")` and the builtins give `"error"`.
- `message` is the text for people.
- `code` is a number such as an exit status or a reply code, or `none`.
- `details` holds extra data as text, `{}` when there is none.
- `cause` is the error that led to this one, or `none`.
- `location` is where the error was made, as `path:line:col`.

Read the fields as on any record, and change one with `with`. Only `error(...)` builds an `Error`: `Error(...)` is `CHECK-ERROR-CONSTRUCTOR`. A program cannot declare a type named `Error` of its own (`CHECK-REDEFINED-NAME`).

```agentica
def parse(text: String) -> Result[Int]
  return error("empty input") if text == ""

  ok(text.length)
end

def main() -> Void
  case parse("")
    ok(n) -> puts(n)
    error(e) ->
      puts(e.message)
      puts(e.kind)
      puts(e.location)
  end
end
```

```output
empty input
error
main.agc:2:10
```

## Kinds

`error(message, kind:, code:, details:, cause:)` takes the other fields as named arguments after the message, each optional and in any order. `code:` takes an `Int` and `cause:` an `Error`, which the call stores as `some(...)`; `location` is never given. `Result.Err(...)` takes the same arguments.

A kind is a dotted name: parts of `a-z`, `0-9` and `_`, each starting with a letter (`db`, `db.constraint`, `io.not_found`). A text literal given as `kind:` that is not one is `CHECK-ERROR-KIND`; a kind computed at run time is kept as it is. A caller branches on the kind or the code, never on the message text.

```agentica
def insert(name: String) -> Result[Int]
  return error("unique failed", kind: "db.constraint", code: 19) if name == "taken"

  ok(name.length)
end

def main() -> Void
  case insert("taken")
    ok(id) -> puts(id)
    error(e) if e.kind == "db.constraint" -> puts("duplicate, code #{e.code}")
    error(e) -> puts(e.message)
  end
end
```

```output
duplicate, code some(19)
```

## Location

`error("text")` sets `location` to the place of that call. An error that a builtin makes gets the place of the builtin call: in the program, or in the `std/` module whose function made the call. A prelude function (`o.to_result(...)`) is skipped, so its error points at the program's call. A function of an `extern module` block gives the place of its declaration. The path is relative: the name the compiled file stores for the source, relative to the folder of the entry file, or `std/...` for a standard module.

`location` is `""` when no place is known: when the call is more than 16 prelude or native frames deep, or when no task is running the code that builds the error.

`error(e)` and `e.with(...)` keep the location of `e`.

## Passing an error on

`error(e)` with an `Error` gives a failed Result that holds that same `Error`, so a `case` arm can pass it on to a `Result` of another type. `try` passes it on unchanged too.

```agentica
def count(text: String) -> Result[Int]
  return error("no digits") if text == ""

  ok(text.length)
end

def label(text: String) -> Result[String]
  case count(text)
    ok(n) -> ok("#{n} digits")
    error(e) -> error(e)
  end
end

def main() -> Void
  puts(label(""))
end
```

```output
error("no digits")
```

## Cause

`cause` links an error to the one that led to it: `error("text", cause: e)`. A chain ends with `none`, and since values cannot change, it cannot loop.

```agentica
def load() -> Result[Int] = error("disk gone")

def start() -> Result[Int]
  case load()
    ok(n) -> ok(n)
    error(e) -> error("cannot start", cause: e)
  end
end

def main() -> Void
  case start()
    ok(_) -> puts("started")
    error(e) ->
      current = some(e)
      while current.some?
        link = current.unwrap!
        puts(link.message)
        current = link.cause
      end
  end
end
```

```output
cannot start
disk gone
```

## Printing

- `to_s`, `puts(e)` and `"#{e}"` give the message.
- `inspect` gives the `error(...)` call that builds the value: the message, then `kind:`, `code:`, `details:` and `cause:` when they are not the defaults. `location` is never printed.
- A bare `Error` prints like a failed Result, so `[e]` prints `[error("x")]`.

```agentica
def main() -> Void
  r: Result[Int] = error("timeout")
  case r
    ok(_) -> puts("ok")
    error(e) ->
      puts(e)
      puts(e.inspect)
      puts([e])
      puts("failed: #{e}")
  end
end
```

```output
timeout
error("timeout")
[error("timeout")]
failed: timeout
```

## Equality

`==` compares `kind`, `message`, `code`, `details` and `cause`, and leaves out `location`, so `Test.eq(parse(""), error("empty input"))` holds although the two errors were made in different places. A `Result` that holds an error compares its `Error` the same way.

## JSON

An `Error` is JSON-encodable, with all six fields; `null` for `none`. `JSON.decode(text, Error)` reads the same shape. A `Result` is not encodable (`CHECK-NOT-ENCODABLE`).

```agentica
def main() -> Void
  r: Result[Int] = error("timeout")
  case r
    ok(_) -> puts("ok")
    error(e) -> puts(JSON.encode(e.with(location: "")))
  end
end
```

```output
{"kind":"error","message":"timeout","code":null,"details":{},"cause":null,"location":""}
```
