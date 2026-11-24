# A crash that reaches main ends the run with its diagnostic, after the notice of the task that crashed.
def boom() -> Int = 10 / 0

def main() -> Void
  idle: Channel[Int] = Channel.new(1)
  _child = Task.spawn_link(&boom)
  puts("waiting")
  puts(idle.recv(5000).unwrap!)
end
