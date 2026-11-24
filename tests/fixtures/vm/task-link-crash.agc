# Task.spawn_link: a crash ends the tasks linked to it with the same diagnostic, up to the parent, then down to its
# other linked children and theirs. The first crash is the only one that counts, and the monitor of the parent
# observes it.
struct Tagged
  name: String
  task: TaskRef
end

struct Lines
  refs: Channel[Tagged]
  idle: Channel[Int]
end

def divide(n: Int) -> Int = 10 / n

def wait(lines: Lines) -> Int = lines.idle.recv(600000).unwrap!

def announce(name: String, lines: Lines) -> Void
  _ = lines.refs.send(Tagged(name: name, task: Task.current), 1000)
end

def reader(lines: Lines) -> Int
  announce("reader", lines)
  divide(0)
end

def deep(lines: Lines) -> Int
  announce("deep", lines)
  wait(lines)
end

def writer(lines: Lines) -> Int
  announce("writer", lines)
  _ = Task.spawn_link(&deep, lines)
  wait(lines)
end

def pair(lines: Lines) -> Int
  _writer = Task.spawn_link(&writer, lines)
  _reader = Task.spawn_link(&reader, lines)
  wait(lines)
end

def main() -> Void
  refs: Channel[Tagged] = Channel.new(8)
  idle: Channel[Int] = Channel.new(1)
  notices: Channel[String] = Channel.new(8)
  parent = Task.spawn(&pair, Lines(refs: refs, idle: idle))
  Task.monitor(parent, notices) do |down| "pair #{down.reason} #{down.code} #{down.line}:#{down.column}" end
  (1..3).each do |_n|
    tagged = refs.recv(5000).unwrap!
    Task.monitor(tagged.task, notices) do |down|
      "#{tagged.name} #{down.reason} #{down.code} #{down.line}:#{down.column}"
    end
  end

  lines = (1..4).map do |_n| notices.recv(5000).unwrap! end
  lines.sort.each do |line| puts(line) end
  puts(Task.unobserved_crash().ok?)
end
