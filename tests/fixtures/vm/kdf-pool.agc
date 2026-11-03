# KDF.scrypt and KDF.pbkdf2_hmac_sha256 run on the thread pool: the deriving task
# parks, and the other task of its scheduler keeps running. The deriving task
# logs "start" before the call and "done" after it; main logs "tick", lets the
# other task run (Task.sleep(0)) and logs "tick" again, far faster than a key
# takes. A call that held its scheduler would end its turn with the key, so at
# one scheduler the log would read start, tick, done, tick. A cancel ends the
# wait at once, and the key of the call, which runs to its end, is dropped while
# the next race runs. The keys match Python's hashlib.
def race(label: String, derive: Fn[Result[Bytes]]) -> Void
  log: Channel[String] = Channel.new(4)
  started: Channel[Bool] = Channel.new(1)
  task = Task.spawn do
    log.send("start", 0)
    started.send(true, 0)
    key = derive.call()
    log.send("done", 0)
    key
  end
  started.recv(60000)
  log.send("tick", 0)
  Task.sleep(0)
  log.send("tick", 0)
  key = Digest.hexencode(Task.await(task).unwrap!)
  words = [log.recv(0).unwrap!, log.recv(0).unwrap!, log.recv(0).unwrap!, log.recv(0).unwrap!]
  puts("#{label}: #{words.join(" ")} #{key}")
end

def cancel_in_flight() -> Void
  started: Channel[Bool] = Channel.new(1)
  task = Task.spawn do
    started.send(true, 0)
    KDF.scrypt("password".bytes, "NaCl".bytes, 1024, 8, 1, 32)
  end
  started.recv(60000)
  Task.cancel(task)
  puts("cancelled: #{Task.await(task)}")
end

def main() -> Void
  race("scrypt") do KDF.scrypt("password".bytes, "NaCl".bytes, 4096, 8, 1, 32) end
  cancel_in_flight()
  race("pbkdf2") do KDF.pbkdf2_hmac_sha256("password".bytes, "NaCl".bytes, 50000, 32) end
end
