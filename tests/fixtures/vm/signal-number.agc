# System.signal_number gives the numbers that Linux, macOS and Windows share, and an empty System.subscribe list is an
# argument error, on every system.
def main() -> Void
  [System.Signal.Term, System.Signal.Int, System.Signal.Hup, System.Signal.Quit, System.Signal.Kill].each do |s|
    puts("#{s} #{System.signal_number(s)}")
  end

  case System.subscribe([])
    ok(_) -> puts("subscribed")
    error(e) -> puts("#{e.kind}: #{e.message}")
  end
end
