# System.signal refuses a pid of zero or less, the program's own pid, and a name that no process can have, on every
# system, before it looks for a pidfd.
def main() -> Void
  puts(System.signal(0, System.Signal.Term, "sleep").message)
  puts(System.signal(System.pid, System.Signal.Term, "agentica").message)
  puts(System.signal(1, System.Signal.Term, "").message)
  puts(System.signal(1, System.Signal.Term, "Runner.Listener+").message)
end
