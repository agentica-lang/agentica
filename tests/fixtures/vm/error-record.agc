# The payload of a failed Result is the builtin Error record. The front end writes the record into every program's
# struct table, and the VM takes it as the builtin one only when its field names and types match
# (agc_error_struct, vm/builtins.c); otherwise every payload stays a String and these lines fail.

def parse(text: String) -> Result[Int]
  return error("empty input") if text == ""

  text.to_i
end

def doubled(text: String) -> Result[Int]
  n = try parse(text)
  ok(n * 2)
end

def described(text: String) -> Result[String]
  n = try doubled(text)
  ok("#{n}")
end

# error(e) passes the same Error on, as a Result of another type.
def relabel(text: String) -> Result[Bool]
  case parse(text)
    ok(n) -> ok(n > 0)
    error(e) -> error(e)
  end
end

def wrapped() -> Result[Int]
  case parse("")
    ok(n) -> ok(n)
    error(e) ->
      outer: Result[Int] = error("cannot start")
      case outer
        ok(n) -> ok(n)
        error(top) -> error(top.with(kind: "config", code: some(7), details: {"step": "load"}, cause: some(e)))
      end
  end
end

def show(label: String, e: Error) -> Void
  puts("#{label}: kind=#{e.kind} message=#{e.message} code=#{e.code} details=#{e.details} at #{e.location}")
end

def echo(e: Error) -> Error = e

def main() -> Void
  # try through two functions keeps the Error and its location.
  case described("")
    ok(text) -> puts(text)
    error(e) -> show("try", e)
  end

  # A builtin made in C, and a std/ prelude function.
  case parse("x1")
    ok(n) -> puts(n)
    error(e) -> show("to_i", e)
  end

  # A File error: kind and code stay their defaults until the builtins get kinds.
  case File.read_text("error-record-missing/none.txt")
    ok(text) -> puts(text)
    # The message is the system's text, which differs between systems.
    error(e) -> puts("file: kind=#{e.kind} code=#{e.code} at #{e.location}")
  end

  missing: Optional[Int] = none
  case missing.to_result("nothing there")
    ok(n) -> puts(n)
    error(e) -> show("to_result", e)
  end

  case relabel("")
    ok(flag) -> puts(flag)
    error(e) -> show("relabel", e)
  end

  # A match on the fields.
  case wrapped()
    ok(n) -> puts(n)
    error(e) if e.kind == "config" and e.code == some(7) ->
      show("wrapped", e)
      link = e.cause
      while link.some?
        show("  cause", link.unwrap!)
        link = link.unwrap!.cause
      end

    error(e) -> show("other", e)
  end

  # Printing: to_s is the message, inspect the error(...) call without defaults or location.
  r = wrapped()
  puts(r)
  puts(r.message)
  case r
    ok(_) -> puts("ok")
    error(e) ->
      puts(e)
      puts("#{e}")
      puts(e.inspect)
      puts([e])
      puts(ok(e))
      puts(e == e.with(location: "elsewhere"))
      puts(e == e.with(message: "other"))
      puts(r == error(e))
      # JSON keeps every field, and decodes back to an equal Error.
      text = JSON.encode(e.with(location: ""))
      puts(text)
      back = JSON.decode(text, Error)
      puts(back.ok? and back.unwrap! == e)
      # A task and a channel copy an Error as any record.
      worker = Task.spawn(&echo, e)
      puts(Task.await(worker) == e)
      box: Channel[Error] = Channel.new(1)
      box.send(e, 1000).unwrap!
      puts(box.recv(1000).unwrap! == e)
  end
end
