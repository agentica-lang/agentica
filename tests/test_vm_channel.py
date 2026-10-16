"""A socket handed to workers over a Channel.

The program listens on port 0 and prints the port; an independent Python peer
connects six clients, and the loop of the workers ends when the channel closes.
"""
from tests.agentica_test import FIXTURES, PYTHON, WAIT_SECONDS, TestCase, run, start_vm

CLIENTS = 6

PROGRAM = """\
struct Pool
  sockets: Channel[Socket]
  id: Int
end

def serve(pool: Pool) -> Int
  handled = 0
  while true
    case pool.sockets.recv(10000)
      ok(socket) ->
        line = Result.unwrap!(TCP.read_line(socket, 10000))
        Result.unwrap!(TCP.send(socket, "worker #{pool.id} got #{line}\\n", 10000))
        TCP.close(socket)
        handled += 1
      error(_) -> break
    end
  end
  return handled
end

def main() -> Void
  sockets: Channel[Socket] = Channel.new(2)
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  puts(TCP.local_port(listener))
  IO.flush()
  workers = [Task.spawn(&serve, Pool(sockets: sockets, id: 0)),
             Task.spawn(&serve, Pool(sockets: sockets, id: 1)),
             Task.spawn(&serve, Pool(sockets: sockets, id: 2))]
  i = 0
  while i < 6
    Result.unwrap!(sockets.send(Result.unwrap!(TCP.accept(listener, 10000)), 10000))
    i += 1
  end
  sockets.close
  handled = workers.map do |worker|
    Task.await(worker)
  end
  TCP.close_listener(listener)
  puts("handled #{handled.reduce(0) do |sum, n| sum + n end}")
end
"""


class VmChannel(TestCase):
    def test_socket_handed_to_a_worker_is_served_and_the_loop_ends_when_the_channel_closes(self):
        # The VM runs beside the peer, so it is a Child read line by line.
        vm = self.adopt(start_vm(self.compile_text(PROGRAM, "pool")))
        port = int(vm.next_line())
        self.assertGreater(port, 0)
        peer = run([PYTHON, FIXTURES / "channel-peer.py", port, CLIENTS], timeout=WAIT_SECONDS)
        self.assertEqual(peer.code, 0, peer.stderr)
        replies = peer.stdout.splitlines()
        self.assertEqual(len(replies), CLIENTS)
        for i, line in enumerate(replies):
            self.assertRegex(line, r"\A%d worker [012] got msg %d\Z" % (i, i))
        self.assertEqual(vm.next_line(), "handled 6")
        self.assertEqual(vm.wait(), 0, "the program ends")
