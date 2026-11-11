import Registry from "lib/registry"
import {NAMES} from "lib/registry"
import {stop} from "lib/registry_stop"

enum Note
  To(Address[Int])
  Nobody
end

struct Link
  name: String
  to: Address[Int]
end

def report(label: String, r: Result[Int]) -> Void
  case r
    ok(n) -> puts("#{label}: ok #{n}")
    error(e) -> puts("#{label}: #{e}")
  end
end

def sent(label: String, r: Result[Void]) -> Void
  case r
    ok(_) -> puts("#{label}: sent")
    error(e) -> puts("#{label}: #{e}")
  end
end

# The owner of the inbox: adds what it gets until a 0.
def counter(inbox: Channel[Int]) -> Result[Int]
  total = 0
  while true
    n = try inbox.recv(5000)
    break if n == 0
    total += n
  end
  ok(total)
end

def client(n: Int) -> Result[Int]
  try Registry.tell("counter", n)
  ok(n)
end

def main() -> Void
  inbox: Channel[Int] = Channel.new(16)
  address = inbox.address
  puts(address)
  puts(address == inbox.address)
  other: Channel[Int] = Channel.new(1)
  puts(other.address)
  puts(address == other.address)
  link = Link(name: "counter", to: address)
  IO.inspect(link)
  IO.inspect([Note.To(address), Note.Nobody])
  IO.inspect({"counter": address}["counter"] == address)

  Registry.register("counter", address)
  owner = Task.spawn_owning(&counter, inbox)
  clients = [1, 2, 3, 4].map do |n: Int| Task.spawn(&client, n) end
  for c in clients
    report("client", Task.await(c))
  end
  sent("stop", stop("counter"))
  report("counter", Task.await(owner))
  puts(NAMES.size)

  sent("after the owner ended", Registry.tell("counter", 5))
  sent("unknown name", Registry.tell("nobody", 5))
end
