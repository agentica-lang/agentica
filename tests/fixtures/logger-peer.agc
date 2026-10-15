import Logger from "std/logger"

def worker(n: Int) -> Int
  Logger.info_meta("from worker", {"n": n.to_s})
  return n
end

def main() -> Void
  while !IO.eof?
    line = IO.gets!
    puts(Logger.time_text(line.to_i!))
  end

  Logger.set_level(LogLevel.Debug)
  gone = Logger.detach("console")
  attached = Logger.attach("json", LogLevel.Debug, &Logger.stderr_json)
  Logger.info("plain")
  Logger.warning_meta("quote \" backslash \\ newline \n tab \t", {"k": "café"})
  Logger.err("unicode 世界 and DEL " + String.from_code(127))
  Logger.debug_meta("fixed keys", {"level": "x", "msg": "y", "time": "z", "task": "9"})
  Logger.info_meta("empty and odd fields", {"": "", "a b": "c=d", "z": "1", "a": "2"})
  first = Task.spawn(&worker, 1)
  second = Task.spawn(&worker, 2)
  puts(Task.await(first) + Task.await(second))
end
