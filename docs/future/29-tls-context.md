## 29. TLS contexts

`TlsContext`, `TLS.upgrade` and ALPN are built (the grammar's network section
and the network library page). Issue #993 holds the options that are still
planned.

### 29.7 Later options

Each is its own item, a new field of the options records (never a new
argument), and each passes the one-way test because nothing else can express it:

- `min_version` (`"1.2"` or `"1.3"`), on both records: today the floor is fixed
  at 1.2.
- `client_ca_file` on `TlsServerOptions`, which makes the server require and
  verify a client certificate. (`cert_file` and `key_file` on
  `TlsClientOptions`, ALPN and `TLS.alpn` are built.)
- `ca_data` on `TlsClientOptions`: PEM text in memory, for a CA that ships
  inside the program. It passes only as the one way for in-memory PEM; it does
  not replace `ca_file` for files.
- `TLS.peer_certificate(socket)`: subject, names, validity. A socket builtin,
  not an option.
- Session reuse (resumption): a per-host session store inside the client
  context, keyed by host and port, with no API. It needs a test that a second
  connection to the same host resumes (Python `ssl` reports `session_reused`)
  and that a context never offers one host's session to another.

**Never** (decided, not proposed again): `SSL_VERIFY_NONE` or any "insecure"
flag, an "optional" verify mode, a hostname-check switch, cipher strings, curve
lists, `openssl.cnf` settings, versions below TLS 1.2, and setters on an
existing context.
