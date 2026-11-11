import Logger from "std/logger"

def show(event: Logger.Event) -> Void
  IO.warn("task #{event.task}: #{event.message} #{event.fields}")
end

def worker(id: Int) -> Int
  i = 0
  while i < 3
    Logger.info("tick", {"worker": id.to_s, "i": i.to_s})
    Task.sleep(0)
    i += 1
  end
  return id
end

def quiet_worker(id: Int) -> Int
  Logger.info("after detach")
  Logger.err("after detach")
  return id
end

def crasher(id: Int) -> Result[Void]
  Logger.err("about to crash")
  Logger.info("not reached")
  return ok()
end

def main() -> Void
  _ = Logger.detach("console")
  _ = Logger.attach("lines", Logger.Level.Info, &show)
  tasks = [Task.spawn(&worker, 10), Task.spawn(&worker, 11), Task.spawn(&worker, 12)]
  for task in tasks
    puts(Task.await(task))
  end

  _ = Logger.detach("lines")
  quiet = [Task.spawn(&quiet_worker, 20), Task.spawn(&quiet_worker, 21)]
  for task in quiet
    puts(Task.await(task))
  end

  _ = Logger.attach("lines", Logger.Level.Info, &show)
  _ = Logger.attach("boom", Logger.Level.Error) do |event|
    IO.warn("boom handler for #{event.message}")
    n = event.task - event.task
    IO.warn("#{1 / n}")
  end
  crashed = Task.spawn(&crasher, 30)
  puts(Task.await(crashed).ok?)
  Logger.info("main goes on")
  puts(Logger.handlers())
  _ = Logger.detach("boom")
  Logger.err("main logs an error")
end
