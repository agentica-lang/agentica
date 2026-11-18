import Logger from "std/logger"

# time_text writes the years 1 to 9999 and halts outside them, Int.max included, with one message in milliseconds.
def check(time_ms: Int) -> Void
  task = Task.spawn(-> { ok(Logger.time_text(time_ms)) })
  case Task.await(task)
    ok(text) -> puts(text)
    error(message) -> puts(message)
  end
end

def main() -> Void
  check(-62135596800000)
  check(253402300799999)
  check(-62135596800001)
  check(253402300800000)
  check(9223372036854775807)
end
