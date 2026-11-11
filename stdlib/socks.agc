## A TCP connection through a SOCKS5 proxy (RFC 1928), with an optional user and password (RFC 1929).
##
## Import it with `import Socks from "std/socks"`. The socket that `connect` gives is a plain `TCP` socket to the
## target: send, receive, upgrade it to TLS and close it as one from `TCP.connect`.

import SocksWire from "std/internal/socks"

## A TCP connection to `host:port` through the SOCKS5 proxy at the URL `proxy`, within `timeout_ms`.
##
## `proxy` is `socks5://host:port` or `socks5h://host:port` (port 1080 when left out), with an optional
## `user:password@` in percent-encoding. `socks5h` sends the target's host name to the proxy, which resolves it;
## `socks5` resolves it here and sends the first address that the system resolver gives. An IP literal goes as an
## address through both. The errors name the proxy and the target, never the user or the password.
export def connect(proxy: String, host: String, port: Int, timeout_ms: Int) -> Result[Socket]
  found = try SocksWire.parse(proxy)
  SocksWire.connect(found, host, port, timeout_ms)
end
