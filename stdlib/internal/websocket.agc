## The wire format of RFC 6455 for the server side of `std/http`.
##
## Import it with `import WebSocketWire from "std/internal/websocket"`. Only a module of `std/` may import a module
## under `std/internal/`; `HTTP` in `std/http` is the only caller. Everything here is a pure function on `Bytes`, `Int`
## and `String`: the handshake (the accept key and the header tokens), the frames the server writes (never masked), and
## the checks a frame from a client must pass (masked, no reserved bits, known opcodes, whole control frames, the size
## cap, the rules of fragments, the UTF-8 of a text message and the close code). The tasks and the socket are in
## `std/http`.
##
## A check that fails is a `Problem`: the close code the server answers with and a reason of at most 123 bytes.
## Unmasking is a loop over the bytes, so it runs at about 7 MB/s: a message of a few MiB costs a fraction of a second.

import Binary from "std/binary"

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
KEY_BYTES = 16
MASK_BYTES = 4
# A control frame carries at most this many bytes, and a close frame keeps 2 of them for its code.
NO_KEY = Bytes.from_list([]).unwrap!
ACCEPT_BYTES = 20
# The bytes of a token (RFC 9110 5.6.2): what a subprotocol name is made of.
TOKEN_BYTES = "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".bytes
CONTROL_BYTES = 125
REASON_BYTES = 123
# The opcodes of RFC 6455 5.2.
CONTINUATION = 0
TEXT = 1
BINARY = 2
CLOSE = 8
PING = 9
PONG = 10

## Normal closure.
export CLOSE_NORMAL = 1000
## A protocol error, the answer to a frame that breaks the rules.
export CLOSE_PROTOCOL = 1002
## Data that is not valid for its type: a text message that is not UTF-8.
export CLOSE_BAD_DATA = 1007
## A message over the size cap.
export CLOSE_TOO_BIG = 1009
## The server's own failure.
export CLOSE_INTERNAL = 1011
## 1006 is never sent: it is what a program is told when the connection ended with no close frame.
export CLOSE_ABNORMAL = 1006

## A failed check: the close code to answer with and why.
export struct Problem
  code: Int
  reason: String
end

## The head of a frame. It is read in two steps: the first two bytes (head_of) and then the tail they announce
## (tail_size, complete). `length` holds the 7-bit length until the tail completes it, and is -1 for a 64-bit length
## that has its top bit set.
export struct Head
  fin: Bool
  opcode: Int
  masked: Bool
  reserved: Int
  length: Int
  key: Bytes
end

## The frames of a message that arrives in fragments: its kind, the pieces so far and their size.
export struct Assembly
  text: Bool
  open: Bool
  parts: List[Bytes]
  total: Int
end

## What one data frame did to the message being assembled.
export enum Taken
  More(Assembly)
  Whole(Bool, Bytes, Assembly)
  Broken(Problem)
end

## What a close frame says: the peer's code and reason, or a problem with the frame.
export enum Closing
  Peer(Int, String)
  Invalid(Problem)
end

## The `Sec-WebSocket-Accept` for a `Sec-WebSocket-Key` (RFC 6455 4.2.2): the base64 of the SHA-1 of the key and
## the GUID.
export def accept_key(key: String) -> String
  return Base64.strict_encode64(Digest.sha1("#{key}#{GUID}".bytes))
end

## A Sec-WebSocket-Accept is the base64 of a SHA-1 digest of 20 bytes: what `accept_key` makes.
export def valid_accept?(accept: String) -> Bool
  case Base64.strict_decode64(accept)
    ok(data) -> return data.size == ACCEPT_BYTES
    error(_) -> return false
  end
end

## True for a name made only of token bytes (no space, comma, control byte or quote), as a subprotocol is. An empty
## name is a token here: it stands for no subprotocol.
export def token?(name: String) -> Bool
  for byte in name.bytes
    if not token_byte?(byte)
      return false
    end
  end

  return true
end

## A Sec-WebSocket-Key is the base64 of 16 random bytes.
export def valid_key?(key: String) -> Bool
  case Base64.strict_decode64(key)
    ok(data) -> return data.size == KEY_BYTES
    error(_) -> return false
  end
end

## True when `value`, a comma-separated list as in `Connection` and `Upgrade`, has `token`, as HTTP compares names.
export def has_token?(value: String, token: String) -> Bool
  for part in value.split(",")
    if part.strip.downcase == token
      return true
    end
  end

  return false
end

## The first two bytes of a frame as a `Head` that has no tail yet.
export def head_of(two: Bytes) -> Head
  first = two.at(0)
  second = two.at(1)
  return Head(
    fin: first >= 128,
    opcode: first % 16,
    masked: second >= 128,
    reserved: (first / 16) % 8,
    length: second % 128,
    key: NO_KEY,
  )
end

## The bytes after the first two: the extended length (2 or 8 bytes) and the mask (4 bytes when the frame is masked).
export def tail_size(head: Head) -> Int
  size = 0
  if head.length == 126
    size = 2
  end

  if head.length == 127
    size = 8
  end

  if head.masked
    size = size + MASK_BYTES
  end

  return size
end

## The head with its length and mask, from the tail `tail_size` counted.
export def complete(head: Head, tail: Bytes) -> Head
  length = head.length
  used = 0
  if head.length == 126
    length = Binary.read_u16_be(tail, 0).unwrap!
    used = 2
  end

  if head.length == 127
    length = Result.unwrap_or(Binary.read_u64_be(tail, 0), -1)
    used = 8
  end

  key = NO_KEY
  if head.masked
    key = tail.slice(used, MASK_BYTES)
  end

  return Head(
    fin: head.fin,
    opcode: head.opcode,
    masked: head.masked,
    reserved: head.reserved,
    length: length,
    key: key,
  )
end

## What is wrong with a head, before any payload is read, when something is.
export def check_head(head: Head) -> Optional[Problem]
  if head.reserved != 0
    return some(Problem(code: CLOSE_PROTOCOL, reason: "reserved bits are set"))
  end

  if not head.masked
    return some(Problem(code: CLOSE_PROTOCOL, reason: "a client frame must be masked"))
  end

  if not known_opcode?(head.opcode)
    return some(Problem(code: CLOSE_PROTOCOL, reason: "unknown opcode"))
  end

  if control?(head.opcode)
    return check_control(head)
  end

  return none
end

## What is wrong with the length of a head whose tail was read: a 64-bit length that is not a length, or a data frame
## that would take its message past the cap, given the `held` bytes of the message's earlier fragments.
export def check_length(head: Head, max: Int, held: Int) -> Optional[Problem]
  if head.length < 0
    return some(Problem(code: CLOSE_PROTOCOL, reason: "invalid frame length"))
  end

  if not control?(head.opcode) and held + head.length > max
    return some(Problem(code: CLOSE_TOO_BIG, reason: "message too big"))
  end

  return none
end

## True for the opcodes of control frames (close, ping, pong).
export def control?(opcode: Int) -> Bool
  return opcode >= CLOSE
end

## True for the close opcode.
export def close?(opcode: Int) -> Bool
  return opcode == CLOSE
end

## True for the ping opcode.
export def ping?(opcode: Int) -> Bool
  return opcode == PING
end

## The payload with the mask of the frame taken off: each byte is xor-ed with the byte of the key at its place mod 4.
export def unmask(data: Bytes, key: Bytes) -> Bytes
  if key.empty?
    return data
  end

  k = key.to_a
  out: List[Int] = []
  place = 0
  for byte in data
    out = out.push(Int.bit_xor(byte, k[place]))
    place = (place + 1) % MASK_BYTES
  end

  return Bytes.from_list(out).unwrap!
end

## The state before the first frame of a message.
export def new_assembly() -> Assembly
  return Assembly(text: false, open: false, parts: [], total: 0)
end

## Adds a data frame (text, binary or continuation) to the message being assembled. The message is whole at its last
## frame, and a text message must then be UTF-8. A fragment that starts a message while another is open, or that
## continues none, breaks the protocol; so does a message past `max` bytes in all.
export def take(assembly: Assembly, head: Head, payload: Bytes, max: Int) -> Taken
  continuing = head.opcode == CONTINUATION
  if continuing and not assembly.open
    return Taken.Broken(Problem(code: CLOSE_PROTOCOL, reason: "a continuation with no message"))
  end

  if not continuing and assembly.open
    return Taken.Broken(Problem(code: CLOSE_PROTOCOL, reason: "a new message inside a fragmented one"))
  end

  text = assembly.text
  if not continuing
    text = head.opcode == TEXT
  end

  total = assembly.total + payload.size
  if total > max
    return Taken.Broken(Problem(code: CLOSE_TOO_BIG, reason: "message too big"))
  end

  parts = assembly.parts.push(payload)
  if not head.fin
    return Taken.More(Assembly(text: text, open: true, parts: parts, total: total))
  end

  return finished(text, Bytes.concat(parts))
end

## A close frame: no payload (no code), or a code of two bytes and a reason that is UTF-8. A code that no peer may send
## (below 1000, 1004 to 1006, 1015 to 2999, past 4999) is a protocol error, as is one byte of payload.
export def parse_close(payload: Bytes) -> Closing
  if payload.empty?
    return Closing.Peer(CLOSE_NORMAL, "")
  end

  if payload.size == 1
    return Closing.Invalid(Problem(code: CLOSE_PROTOCOL, reason: "a close frame with one byte"))
  end

  code = Binary.read_u16_be(payload, 0).unwrap!
  if not valid_code?(code)
    return Closing.Invalid(Problem(code: CLOSE_PROTOCOL, reason: "invalid close code"))
  end

  case String.from_bytes(payload.drop(2))
    ok(reason) -> return Closing.Peer(code, reason)
    error(_) -> return Closing.Invalid(Problem(code: CLOSE_BAD_DATA, reason: "close reason is not valid UTF-8"))
  end
end

## A frame the server writes: the first byte (FIN set and the opcode), the length and the payload, never masked.
export def frame(opcode: Int, payload: Bytes) -> Bytes
  size = payload.size
  head = Bytes.from_list([128 + opcode]).unwrap!
  if size < 126
    return Bytes.concat([head, Bytes.from_list([size]).unwrap!, payload])
  end

  if size < 65536
    return Bytes.concat([head, Bytes.from_list([126]).unwrap!, Binary.write_u16_be(size).unwrap!, payload])
  end

  return Bytes.concat([head, Bytes.from_list([127]).unwrap!, Binary.write_i64_be(size), payload])
end

## A text frame the server writes.
export def text_frame(text: String) -> Bytes
  return frame(TEXT, text.bytes)
end

## A binary frame the server writes.
export def binary_frame(data: Bytes) -> Bytes
  return frame(BINARY, data)
end

## A ping frame the server writes.
export def ping_frame(data: Bytes) -> Bytes
  return frame(PING, data)
end

## A pong frame the server writes.
export def pong_frame(data: Bytes) -> Bytes
  return frame(PONG, data)
end

## A close frame; the reason is cut to what a control frame can hold, at a character boundary.
export def close_frame(code: Int, reason: String) -> Bytes
  return frame(CLOSE, Bytes.concat([Binary.write_u16_be(code).unwrap!, short_reason(reason)]))
end

## True for a close code that a peer may send: 1000 to 1014 except 1004 to 1006, and 3000 to 4999.
export def valid_code?(code: Int) -> Bool
  if code >= 3000 and code <= 4999
    return true
  end

  return code >= 1000 and code <= 1014 and code != 1004 and code != 1005 and code != 1006
end

def known_opcode?(opcode: Int) -> Bool
  return opcode <= BINARY or (opcode >= CLOSE and opcode <= PONG)
end

# A control frame is whole and short. Its length field says so before the tail is read: 126 and 127 are too long.
def check_control(head: Head) -> Optional[Problem]
  if not head.fin
    return some(Problem(code: CLOSE_PROTOCOL, reason: "a control frame cannot be fragmented"))
  end

  if head.length > CONTROL_BYTES
    return some(Problem(code: CLOSE_PROTOCOL, reason: "a control frame is at most 125 bytes"))
  end

  return none
end

def finished(text: Bool, data: Bytes) -> Taken
  if text and not utf8?(data)
    return Taken.Broken(Problem(code: CLOSE_BAD_DATA, reason: "text is not valid UTF-8"))
  end

  return Taken.Whole(text, data, new_assembly())
end

# The reason as bytes of at most 123, without splitting a character.
def short_reason(reason: String) -> Bytes
  data = reason.bytes
  if data.size <= REASON_BYTES
    return data
  end

  size = REASON_BYTES
  while size > 0 and not utf8?(data.take(size))
    size = size - 1
  end

  return data.take(size)
end

def utf8?(data: Bytes) -> Bool
  case String.from_bytes(data)
    ok(_) -> return true
    error(_) -> return false
  end
end

def token_byte?(byte: Int) -> Bool
  for allowed in TOKEN_BYTES
    if allowed == byte
      return true
    end
  end

  return false
end
