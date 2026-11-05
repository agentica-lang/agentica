# A coordinator that restarts a crashed worker: every worker is monitored on the coordinator's one channel, which
# carries both the results and the notices.
struct Job
  id: Int
  attempt: Int
end

enum Msg
  Done(Int, Int)
  Down(TaskDown)
end

def work(job: Job, inbox: Channel[Msg]) -> Void
  if job.id == 2 and job.attempt == 1
    puts("never #{[1][job.id]}")
  end

  _ = inbox.send(Msg.Done(job.id, job.id * 10), 1000)
end

def start(job: Job, inbox: Channel[Msg], running: Map[Int, Job]) -> Map[Int, Job]
  task = Task.spawn do work(job, inbox) end
  Task.monitor(task, inbox) do |down| Msg.Down(down) end
  return running.put(task.id, job)
end

def main() -> Void
  inbox: Channel[Msg] = Channel.new(16)
  running: Map[Int, Job] = {}
  for id in 1..3
    running = start(Job(id: id, attempt: 1), inbox, running)
  end

  results: List[String] = []
  while running.size > 0
    case inbox.recv(5000).unwrap!
      Msg.Done(id, value) -> results = results.push("job #{id} gave #{value}")
      Msg.Down(down) ->
        job = running[down.task_id]
        running = running.delete(down.task_id)
        case down.reason
          TaskExit.Crashed ->
            puts("job #{job.id} crashed on attempt #{job.attempt} with #{down.code}, restarting")
            running = start(job.with(attempt: job.attempt + 1), inbox, running)
          _ -> running = running
        end
    end
  end

  puts(results.sort)
end
