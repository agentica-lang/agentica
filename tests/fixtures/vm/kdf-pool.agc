# KDF.scrypt and KDF.pbkdf2_hmac_sha256 run on the compute pool: the deriving
# task parks, and the other task of its scheduler keeps running. The deriving
# task logs "start" before the call and "done" after it; main logs "tick", lets
# the other task run (Task.sleep(0)) and logs "tick" again. Each key takes about
# 0.1 s, thousands of times what main needs. A call that held its scheduler
# would end its turn with the key, so at one scheduler the log would read start,
# tick, done, tick. A cancel ends the wait at once: a call that has started runs
# to its end and its key is dropped, one that has not is skipped. At one
# scheduler the pool has one thread, so the call of cancel_queued waits behind
# the scrypt ahead of it and is always skipped, and the key ahead is right. The
# keys match Python's hashlib.
def race(label: String, derive: Fn[Result[Bytes]]) -> Void
  log: Channel[String] = Channel.new(4)
  started: Channel[Bool] = Channel.new(1)
  task = Task.spawn do
    _ = log.send("start", 0)
    _ = started.send(true, 0)
    key = derive.call()
    _ = log.send("done", 0)
    key
  end
  _ = started.recv(60000)
  _ = log.send("tick", 0)
  Task.sleep(0)
  _ = log.send("tick", 0)
  key = Digest.hexencode(Task.await(task).unwrap!)
  words = [log.recv(0).unwrap!, log.recv(0).unwrap!, log.recv(0).unwrap!, log.recv(0).unwrap!]
  puts("#{label}: #{words.join(" ")} #{key}")
end

def cancel_one() -> Void
  started: Channel[Bool] = Channel.new(1)
  task = Task.spawn do
    _ = started.send(true, 0)
    KDF.scrypt("password".bytes, "NaCl".bytes, 1024, 8, 1, 32)
  end
  _ = started.recv(60000)
  Task.cancel(task)
  puts("cancelled: #{Task.await(task)}")
end

def cancel_queued() -> Void
  started: Channel[Bool] = Channel.new(1)
  ahead = Task.spawn do
    _ = started.send(true, 0)
    KDF.scrypt("password".bytes, "NaCl".bytes, 16384, 8, 1, 32)
  end
  _ = started.recv(60000)
  queued = Task.spawn do
    _ = started.send(true, 0)
    KDF.pbkdf2_hmac_sha256("password".bytes, "NaCl".bytes, 1, 32)
  end
  _ = started.recv(60000)
  Task.cancel(queued)
  puts("queued: #{Task.await(queued)}")
  puts("ahead: #{Digest.hexencode(Task.await(ahead).unwrap!)}")
end

def main() -> Void
  race("scrypt") do KDF.scrypt("password".bytes, "NaCl".bytes, 16384, 8, 1, 32) end
  cancel_one()
  cancel_queued()
  race("pbkdf2") do KDF.pbkdf2_hmac_sha256("password".bytes, "NaCl".bytes, 150000, 32) end
end
