import Logger from "std/logger"

def scale() -> Int
  return 1
end

def noop(message: String) -> Void
end

def main() -> Void
  calls = 1000000 * scale()
  total = 0

  started = Time.monotonic_ms()
  i = 0
  while i < calls
    total += i % 7
    i += 1
  end
  empty = Time.monotonic_ms() - started

  started = Time.monotonic_ms()
  i = 0
  while i < calls
    noop("message")
    total += i % 7
    i += 1
  end
  user_call = Time.monotonic_ms() - started

  started = Time.monotonic_ms()
  i = 0
  while i < calls
    Logger.debug("message")
    total += i % 7
    i += 1
  end
  disabled = Time.monotonic_ms() - started

  Logger.set_level(LogLevel.Debug)
  started = Time.monotonic_ms()
  i = 0
  while i < calls
    Logger.debug("message")
    total += i % 7
    i += 1
  end
  unaccepted = Time.monotonic_ms() - started

  IO.warn("#{calls} iterations: empty loop #{empty} ms, empty user call #{user_call} ms, disabled Logger.debug #{disabled} ms, debug that no handler accepts #{unaccepted} ms")
  puts("logger-disabled #{calls}: checksum #{total}")
end
