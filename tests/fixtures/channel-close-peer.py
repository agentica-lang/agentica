"""The expected output of a Channel operation list, from a Python model of one channel (tests/test_vm_channel.py).

Reads the operations as JSON on stdin, one [name, argument] each, and prints what the Agentica program of the same
list prints. Every call is made with timeout 0, so a full send or an empty receive times out. A close keeps its
reason, if any; a second close changes nothing. Receivers get the values left, then the reason (or the closed error);
senders get the reason at once. --capacity N sets the capacity of each new channel.
"""
import argparse
import collections
import json
import sys

CLOSED = "channel.closed channel: closed"
TIMED_OUT = "channel.timeout channel: timed out"


class Channel:
    def __init__(self, capacity):
        self.capacity = capacity
        self.values = collections.deque()
        self.closed = False
        self.reason = None

    def end(self):
        return "stream.cut " + self.reason if self.reason is not None else CLOSED

    def send(self, value):
        if self.closed:
            return self.end()
        if len(self.values) >= self.capacity:
            return TIMED_OUT
        self.values.append(value)
        return "ok"

    def recv(self):
        if self.values:
            return str(self.values.popleft())
        return self.end() if self.closed else TIMED_OUT

    def close(self, reason=None):
        if not self.closed:
            self.closed = True
            self.reason = reason


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--capacity", type=int, required=True)
    capacity = parser.parse_args().capacity
    channel = Channel(capacity)
    for name, argument in json.load(sys.stdin):
        if name == "new":
            channel = Channel(capacity)
        elif name == "put":
            assert channel.send(argument) == "ok"
        elif name in ("send", "address_send"):
            print("%s %d %s" % (name, argument, channel.send(argument)))
        elif name == "recv":
            print("recv " + channel.recv())
        elif name == "close":
            channel.close()
        elif name == "close_reason":
            channel.close(argument)
        elif name == "closed":
            print("closed? " + ("true" if channel.closed else "false"))
        elif name == "empty":
            print("empty? " + ("false" if channel.values else "true"))
        else:
            raise SystemExit("unknown operation " + name)


main()
