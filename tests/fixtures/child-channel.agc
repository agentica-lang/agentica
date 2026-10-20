def show(label: String, result: Result[String]) -> Void
  puts("#{label}: #{result.inspect}")
end

def done(label: String, result: Result[Void]) -> Void
  puts("#{label}: #{result.inspect}")
end

def serve() -> Void
  line = Process.parent_read_line(5000)
  while line.ok?
    done("sent", Process.parent_send("echo:" + line.unwrap! + "\n", 5000))
    line = Process.parent_read_line(5000)
  end
  puts("ended: #{line.message}")
  done("bye", Process.parent_send("bye\n", 5000))
end

def idle() -> Void
  show("first", Process.parent_read_line(300))
  show("second", Process.parent_read_line(300))
  done("send", Process.parent_send("late\n", 300))
end

def bare() -> Void
  show("read", Process.parent_read_line(100))
  done("send", Process.parent_send("x\n", 100))
  done("zero", Process.parent_send("x\n", 0))
end

def pinned() -> Void
  show("read", Process.parent_read_line(100))
  done("send", Process.parent_send("x\n", 100))
  puts("ready")
  IO.flush()
  IO.gets()
end

def piped() -> Void
  show("read", Process.parent_read_line(3000))
  puts("ready")
  IO.flush()
  IO.gets()
end

def spawn_shell(script: String, channel: Bool) -> Void
  args = ["-c", script]
  spawned = Process.spawn_captured("sh", args, ".", 5000)
  if channel
    spawned = Process.spawn_channel("sh", args, ".", 5000)
  end
  p = spawned.unwrap!
  puts(Process.output(p, 5000).unwrap!.stdout)
  Process.close(p)
end

def spawning() -> Void
  probe = "echo \"${AGENTICA_CHANNEL-unset}\"; if [ -S /dev/fd/3 ]; then echo socket; else echo closed; fi"
  spawn_shell(probe, false)
  spawn_shell(probe, true)
end

def ask(peer_program: String, peer: String, mode: String) -> Void
  p = Process.spawn_channel(peer_program, [peer, "child", mode], ".", 5000).unwrap!
  Process.close_stdin(p, 1000)
  if mode == "echo"
    done("send", Process.channel_send(p, "hello\n", 2000))
    show("read", Process.channel_read_line(p, 2000))
    show("printed", Process.read_available(p, 1000))
    show("printed again", Process.read_available(p, 1000))
    done("close", Process.channel_close(p, 1000))
    done("send after close", Process.channel_send(p, "x\n", 1000))
    show("end", Process.channel_read_line(p, 2000))
    puts("exit: #{Process.wait(p, 3000).inspect}")
  elsif mode == "silent"
    show("first", Process.channel_read_line(p, 300))
    show("second", Process.channel_read_line(p, 300))
    done("send", Process.channel_send(p, "x\n", 300))
    show("printed", Process.read_available(p, 300))
  elsif mode == "stalled"
    chunk = List.repeat("x", 1048000).join("") + "\n"
    sent = Process.channel_send(p, chunk, 300)
    count = 1
    while sent.ok? and count < 64
      sent = Process.channel_send(p, chunk, 300)
      count = count + 1
    end
    done("send", sent)
    done("after", Process.channel_send(p, "x\n", 300))
  elsif mode == "long"
    show("read", Process.channel_read_line(p, 5000))
    show("again", Process.channel_read_line(p, 300))
  elsif mode == "loud"
    show("read", Process.channel_read_line(p, 5000))
    show("printed", Process.read_available(p, 1000))
  elsif mode == "split"
    show("first", Process.channel_read_line(p, 5000))
    show("printed", Process.read_available(p, 1000))
    done("send", Process.channel_send(p, "go\n", 1000))
    show("second", Process.channel_read_line(p, 5000))
    show("printed", Process.read_available(p, 1000))
  elsif mode == "gone"
    puts("exit: #{Process.wait(p, 3000).inspect}")
    show("end", Process.channel_read_line(p, 2000))
    done("close", Process.channel_close(p, 1000))
    done("close again", Process.channel_close(p, 1000))
  end
  Process.close(p)
end

def plain(peer_program: String, peer: String) -> Void
  p = Process.spawn_captured(peer_program, [peer, "child", "plain"], ".", 5000).unwrap!
  show("read", Process.channel_read_line(p, 300))
  done("send", Process.channel_send(p, "x\n", 300))
  done("close", Process.channel_close(p, 300))
  puts("exit: #{Process.wait(p, 3000).inspect}")
  show("printed", Process.read_available(p, 3000))
  Process.close(p)
  q = Process.spawn(peer_program, ["--version"], 1000).unwrap!
  show("not captured", Process.read_available(q, 300))
  Process.close(q)
end

def main() -> Void
  args = System.args()
  mode = args[0]
  if mode == "serve"
    serve()
  elsif mode == "idle"
    idle()
  elsif mode == "bare"
    bare()
  elsif mode == "spawning"
    spawning()
  elsif mode == "pinned"
    pinned()
  elsif mode == "piped"
    piped()
  elsif mode == "plain"
    plain(args[1], args[2])
  else
    ask(args[1], args[2], mode)
  end
end
