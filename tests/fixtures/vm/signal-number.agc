# System.signal_number gives the numbers that Linux, macOS and Windows share, an empty System.subscribe list is an
# argument error, and Winch (a terminal resize) can be subscribed to, on every system.
def main() -> Void
  signals = [System.Signal.Term, System.Signal.Int, System.Signal.Hup, System.Signal.Winch, System.Signal.Quit]
  for s in signals.push(System.Signal.Kill)
    puts("#{s} #{System.signal_number(s)}")
  end

  case System.subscribe([])
    ok(_) -> puts("subscribed")
    error(e) -> puts("#{e.kind}: #{e.message}")
  end

  case System.subscribe([System.Signal.Winch])
    ok(resized) -> puts("subscribed: #{resized.recv(0).message}")
    error(e) -> puts("#{e.kind}: #{e.message}")
  end
end
