"""A minimal RFC 6455 client on the standard library: the independent peer for the VM's WebSocket server.

It shares no code with the server. It writes frames by hand, so a test can send what a correct client never would
(an unmasked frame, a reserved bit, a fragmented ping, a length that the payload does not match) and read the frames
the server answers with. Server frames must never be masked; `recv` fails the test when one is.
"""
import base64
import hashlib
import os
import socket
import ssl
import struct

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

CONTINUATION, TEXT, BINARY, CLOSE, PING, PONG = 0, 1, 2, 8, 9, 10


def accept_of(key):
    """The Sec-WebSocket-Accept a server must answer for `key` (RFC 6455 4.2.2)."""
    return base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()


def mask(data, key):
    return bytes(byte ^ key[place % 4] for place, byte in enumerate(data))


class Client:
    def __init__(self, port, secure=None, timeout=10):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        if secure is not None:
            self.sock = secure.wrap_socket(self.sock, server_hostname="localhost")
        self.buffer = b""

    def close(self):
        self.sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def read(self, count):
        while len(self.buffer) < count:
            more = self.sock.recv(65536)
            if not more:
                raise EOFError("the connection closed")
            self.buffer += more
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def request(self, path="/", headers=None, method="GET", key=None, version="13", upgrade=True):
        """Sends a handshake and returns (status, headers with lower-case names, the key sent)."""
        key = key or base64.b64encode(os.urandom(16)).decode()
        lines = ["%s %s HTTP/1.1" % (method, path), "Host: localhost"]
        if upgrade:
            lines += ["Upgrade: websocket", "Connection: Upgrade"]
        if version:
            lines.append("Sec-WebSocket-Version: " + version)
        if key != "none":
            lines.append("Sec-WebSocket-Key: " + key)
        lines += ["%s: %s" % item for item in (headers or {}).items()]
        self.sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        return self.response() + (key,)

    def response(self):
        while b"\r\n\r\n" not in self.buffer:
            more = self.sock.recv(65536)
            if not more:
                raise EOFError("the connection closed before the answer")
            self.buffer += more
        head, _, self.buffer = self.buffer.partition(b"\r\n\r\n")
        status, *fields = head.decode().split("\r\n")
        headers = dict(field.split(": ", 1) for field in fields)
        length = int(headers.get("Content-Length", 0))
        if length:
            self.read(length)
        return int(status.split(" ")[1]), {name.lower(): value for name, value in headers.items()}

    def connect(self, path="/", headers=None):
        """A handshake that must succeed, checked against the key sent."""
        status, headers, key = self.request(path, headers)
        assert status == 101, status
        assert headers["upgrade"].lower() == "websocket"
        assert headers["sec-websocket-accept"] == accept_of(key)
        return headers

    def send(self, opcode, payload=b"", fin=True, masked=True, rsv=0, length=None):
        """One frame. `length` is the length announced when it is not the payload's."""
        size = len(payload) if length is None else length
        head = bytes([(128 if fin else 0) | (rsv << 4) | opcode])
        flag = 128 if masked else 0
        if size < 126:
            head += bytes([flag | size])
        elif size < 65536:
            head += bytes([flag | 126]) + struct.pack(">H", size)
        else:
            head += bytes([flag | 127]) + struct.pack(">Q", size)
        if masked:
            key = os.urandom(4)
            payload = key + mask(payload, key)
        self.sock.sendall(head + payload)

    def text(self, text, **options):
        self.send(TEXT, text.encode(), **options)

    def binary(self, data, **options):
        self.send(BINARY, data, **options)

    def close_with(self, code, reason=""):
        self.send(CLOSE, struct.pack(">H", code) + reason.encode())

    def recv(self):
        """The next frame of the server as (fin, opcode, payload)."""
        first, second = self.read(2)
        assert second < 128, "the server masked a frame"
        size = second
        if size == 126:
            size = struct.unpack(">H", self.read(2))[0]
        elif size == 127:
            size = struct.unpack(">Q", self.read(8))[0]
        return first >= 128, first & 15, self.read(size)

    def message(self):
        """The next message, skipping nothing: (opcode, payload) of a whole data frame or a control frame."""
        fin, opcode, payload = self.recv()
        assert fin
        return opcode, payload

    def close_frame(self):
        """The close frame the server answers with, as (code, reason); the next read is the end of the connection."""
        opcode, payload = self.message()
        assert opcode == CLOSE, opcode
        return struct.unpack(">H", payload[:2])[0], payload[2:].decode()

    def ended(self):
        """True when the server closed the connection (a reset counts)."""
        try:
            return self.sock.recv(1) == b""
        except (ConnectionError, ssl.SSLError):
            return True
