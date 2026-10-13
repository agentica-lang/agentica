### File modules and imports

Each file is a module. Use `import "models" as Models` at the top level.
An import path names a module without its extension: `"models"` loads
`models.agc`, and `"../lib/util"` loads `../lib/util.agc`. There is one
spelling: a path that ends in `.agc` gives `CHECK-IMPORT-PATH` with a help that
shows the path without it. An empty path, a path that ends in `/`, and a last
part that contains a dot (`"models.rb"`, `"."`, `".."`) give `CHECK-IMPORT-PATH`
too. So a module file name has no dot apart from `.agc`: `json.tools.agc`
cannot be imported; rename it, for example to `json_tools.agc`. Relative paths resolve from the importing file, not the working
directory. Canonical paths identify files; each file is linked once. Cycles give
`CHECK-IMPORT-CYCLE`; missing or unreadable imports give `CHECK-IMPORT-IO`, and
invalid paths give `CHECK-IMPORT-PATH`. Each is located at the import.

`export struct User ... end`, `export enum Option[T] ... end`, and `export def greet(...) ... end` expose
declarations; everything else is private. Use `Models.User` in annotations and
JSON type arguments, `Models.User(name: "Ana")` for construction,
`Models.greet(user)` for calls, and `&Models.greet` for callbacks. For enums, use `Domain.Option[T]` as a type and `Domain.Option.Some(value)` or `Domain.Option.None()` for variants.
Local names remain unqualified inside their file. Import aliases are uppercase
and cannot collide with declarations, other aliases, or builtin names.
Imports cannot be re-exported. Exported signatures may mention private types,
but importers cannot name or construct those private types.

Only the root file supplies the executable `main() -> Void`. Imported main
functions do not run automatically. Linking preserves source spans and distinct
module identities; imported calls/tasks share the program's execution budget
and resource ownership. CLI check/run/dump and `agentica test` use the same loader.
There are no wildcard imports, package registry, module state, nested module
blocks, or receiver attachment. `as` is contextual in imports, not reserved.

#### Standard library and external libraries

Two prefixes select library resolution:

- `import "std/queue" as Queue` loads the standard library embedded at
  build time. No stdlib installation, environment variable, or repository
  checkout is needed at runtime. Local files and external roots cannot shadow it.
- `import "pkg/acme/tools" as Tools` searches for `acme/tools.agc` in:
  1. `agc_libs/` beside the root program (not beside each dependency or in cwd).
  2. Absolute roots in `AGENTICA_PATH`, in listed order.
  3. `$XDG_DATA_HOME/agentica/lib/`, defaulting to
     `~/.local/share/agentica/lib/`.
  4. `/usr/local/share/agentica/lib/`, then `/usr/share/agentica/lib/`.

On Windows, `AGENTICA_PATH` uses `;` instead of `:`, the user root is
`%LOCALAPPDATA%/agentica/lib/` (fallback `~/AppData/Local/agentica/lib/`),
and there are no default system roots. On other platforms the paths above apply.
An unset or relative user-data environment variable uses the fallback directory.
Empty `AGENTICA_PATH` entries are ignored; relative entries give
`CHECK-IMPORT-PATH` when resolving a `pkg/` import. First existing file wins;
a read or syntax error in that file does not fall back to another root.

Library paths use forward slashes and reject empty, `.`, `..`, backslash,
and colon components. External targets must remain inside their selected root
after symlink resolution. These restrictions apply to namespaced imports, not
to ordinary relative dependencies: imports are not a filesystem sandbox.
Missing modules give `CHECK-IMPORT-IO` at the import. Other imports retain
their existing file-relative behavior; there is no implicit search fallback.
Embedded-module diagnostics name their source, for example `std/queue.agc`.
Embedded dependencies may use relative paths within their stdlib directory.
External modules may use ordinary relative imports for their dependencies.

#### String queue

`std/queue` (the file `std/queue.agc`) is a non-native library written in Agentica. Its exported
immutable records are `QueueState(items: List[String])` and
`Popped(value: String, remaining: QueueState)`.

With the alias `Queue`:

```text
Queue.new() -> Queue.QueueState
Queue.push(q: Queue.QueueState, value: String) -> Queue.QueueState
Queue.pop(q: Queue.QueueState) -> Result[Queue.Popped]
Queue.peek(q: Queue.QueueState) -> Result[String]
Queue.size(q: Queue.QueueState) -> Int
Queue.empty?(q: Queue.QueueState) -> Bool
```

Push adds at the back; pop removes the oldest value. Empty pop/peek return an
error Result. Inputs remain unchanged; assign the returned queue (or
`Popped.remaining`) to continue. Empty strings and duplicates are valid.
QueueState is a normal exported struct, not an opaque handle. There are no
user generics or blocking cross-task queue operations.
The implementation uses Lists: push, pop, peek, size and empty? are O(n)
with the current host list operations; new is O(1). No constant-time FIFO
performance is promised.

#### HTTP client and server (`std/http`)

HTTP is the `std/http` library, imported with `import "std/http" as HTTP`
(`HTTP` is the documented alias; any other alias works too). It has a
client and a server.

```text
HTTP.client_options() -> HttpClientOptions
HTTP.client(options: HttpClientOptions) -> Result[HttpClient]
HTTP.close_client(client: HttpClient) -> Void
HTTP.get(client: HttpClient, url: String) -> Result[HttpResponse]
HTTP.post(client: HttpClient, url: String, headers: List[Header], body: String) -> Result[HttpResponse]
HTTP.request(client: HttpClient, method: String, url: String, headers: List[Header], body: String) -> Result[HttpResponse]
HTTP.header_values(headers: List[Header], name: String) -> List[String]
```

`HttpResponse(status: Int, headers: List[Header], body: String)` is a builtin
record. Every call is whole: it returns after the whole body was read, and
the body must be valid UTF-8. `client_options()` gives a 30 s timeout, a 30 s
idle timeout, 4 connections per origin, a 1 MiB body limit and system CA
trust; options must be positive, `max_connections` at most 65536 and
`max_body_bytes` at most 64 MiB. One `timeout_ms` covers the whole call:
the wait for a pooled connection, DNS, connect, the TLS handshake, the
request and the whole response. The client keeps idle keep-alive connections
per scheme, host and port, and calls wait in FIFO order for one of the
`max_connections` slots. `close_client` closes them; a call in flight then
fails with "http: client is closed". A `GET`, `HEAD`, `OPTIONS`, `PUT` or
`DELETE` sent on a reused keep-alive connection that the server had
already closed is retried once on a new connection, within the same
timeout, when no byte of a response arrived; `POST`, `PATCH` and other
methods are never retried and return the error.

URLs are `http://` or `https://` with a host, an optional port (1..65535)
and an optional path and query; the fragment is dropped, user info is
rejected and IPv6 hosts go in brackets. The client adds `Host` and, when
there is a body or the method is `POST`, `PUT` or `PATCH`, `Content-Length`;
a request that sets `Host`, `Content-Length`, `Transfer-Encoding` or
`Connection` itself is an error. Response header names are lowercase. 4xx
and 5xx are normal responses. A response must be `HTTP/1.1` with a status
of 100 to 599; at most 15 interim responses are skipped and a 101 is an
error. A chunked or close-delimited response body is decoded whole, its
trailers are checked and dropped, and `Content-Encoding` stays raw (no
gzip). A bad options record is an error Result. Errors are Results. Protocol and limit
errors start with `http: `; connection errors keep the TCP and TLS texts
(`tcp-connect: ...`, `ssl-connect: ...`, `error reading from stream port`,
`error writing to stream port`), and a timeout is `network: operation timed
out`. A bracketed host must be an IPv6 literal (hex digits, `:` and `.`).
`std/http` calls the internal module `HttpWire`, which no other module can
name (`CHECK-UNKNOWN-NAME`).

```text
HTTP.server_options() -> HttpServerOptions
HTTP.listen(host: String, port: Int, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions) -> Result[HttpServer]
HTTP.listen_tls(host: String, port: Int, cert_file: String, key_file: String, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions) -> Result[HttpServer]
HTTP.local_port(server: HttpServer) -> Int
HTTP.wait(server: HttpServer) -> Result[Void]
HTTP.close_server(server: HttpServer) -> Void
```

```agentica
import "std/http" as HTTP

def handle(request: HttpRequest) -> Result[HttpResponse]
  if request.method == "GET" and request.path == "/"
    return ok(HttpResponse(status: 200, headers: [Header(name: "Content-Type", value: "text/plain; charset=utf-8")], body: "hello\n"))
  end
  return ok(HttpResponse(status: 404, headers: [], body: "not found\n"))
end

def main() -> Void
  server = HTTP.listen("127.0.0.1", 0, &handle, HTTP.server_options()).unwrap!
  client = HTTP.client(HTTP.client_options()).unwrap!
  response = HTTP.get(client, "http://127.0.0.1:#{HTTP.local_port(server)}/").unwrap!
  puts(response.status)
  HTTP.close_client(client)
  HTTP.close_server(server)
end
```

`listen` opens a TCP listener (port 0 picks a free port, which
`local_port` returns) and `listen_tls` a TLS one from PEM files, then
serve in the background: each connection runs in its own task, which
reads a request, calls the handler, writes its response and, with
keep-alive, reads the next one. The handler gets a whole request:
`HttpRequest(method: String, target: String, path: String, headers:
List[Header], body: String)`, where `target` is the request target as sent,
`path` is the part before `?`, header names are lowercase and the body is
valid UTF-8. It returns a whole `HttpResponse`; the server adds
`Content-Length` (except on 204 and 304, which must have an empty body),
`Date` unless the handler set it, and `Connection: close` when either side
asked for it, and sends no body for `HEAD` (whose `Content-Length` is that of the body it would have sent). A handler that returns
`error(message)`, or a response that cannot be sent (a status outside 200
to 599, a bad header, a `Content-Length` or `Transfer-Encoding` header, a
body with 204 or 304), gives the client a 500 with an empty body and
closes the connection; stderr gets one line, `http: handler error:
<message>` or `http: invalid response: <reason>`. The handler has no time
limit. A runtime error in a handler crashes its connection task: the
client sees the connection close, the server goes on, and the run reports
the crash as any task crash (it exits 1 at the end unless something
observed it).

`server_options()` gives `HttpServerOptions(request_timeout_ms: 30000,
idle_timeout_ms: 30000, max_connections: 128, max_body_bytes: 1048576)`,
with the client's option checks. `request_timeout_ms` bounds the wait for
the first byte of a connection's first request, then the rest of each
request from its first byte, and, from the handler's return, the write of
its response; `idle_timeout_ms` bounds the wait for a later request on a
kept-alive connection. At most `max_connections` connections are served at
once; more wait in the listener's backlog. Requests the server rejects
before the handler runs get an empty answer and a close: 400 for a
malformed request or a body that is not UTF-8, 413 for a body over
`max_body_bytes` (before any `100 Continue` when the `Content-Length` is
over), 417 for an `Expect` other than `100-continue`, 431 for a line, the
head or the header count over the limits, 501 for `CONNECT`, `Upgrade` and
`Transfer-Encoding` other than one `chunked`, and 505 for any version but
`HTTP/1.1`. `wait` returns `ok()` once the server is closed.
`close_server` closes the listener, ends every connection, and cancels the
handlers and every task they spawned; it is idempotent. When `main`
returns, the run ends whatever the server is doing. If the client leaves
while the response is written, the connection closes quietly. Memory for
bodies can reach `max_body_bytes` times `max_connections` times 4 (a body
is held once in C and once as a `String`, on each side), so a program that
raises `max_body_bytes` should lower `max_connections` to match.

Migration from the builtin `HTTP` module, which roadmap 7i removed: add `import "std/http" as HTTP`; `HTTP.client()` becomes `HTTP.client(HTTP.client_options())`. `get`, `post` and `request` return a whole `HttpResponse`, so `HTTP.text(response.body, t)` becomes `response.body`; `max_body_bytes` defaults to 1 MiB (it was 64 MiB), `timeout_ms` covers the whole response, and a body that is not UTF-8 is an error. `HTTP.read`, `trailers`, `close_body` and `request_stream` are gone (send a whole `HTTP.request`; streaming is planned on channels). A server handler `def handle(request: Request, writer: HttpWriter) -> Void` that called `HTTP.respond(writer, status, headers, text, timeout_ms)` becomes `def handle(request: HttpRequest) -> Result[HttpResponse]` that returns `ok(HttpResponse(status: status, headers: headers, body: text))`. `HTTP.begin`, `write`, `write_bytes` and `finish` are gone (no streaming responses, no trailers), `HttpServerOptions` has `request_timeout_ms` instead of `header_timeout_ms`, and `Request`, `Response`, `HttpBody` and `HttpWriter` are no longer types.

#### BDD steps (`std/bdd`)

`std/bdd` is the step API of `agentica test`, written in Agentica. With the
alias `BDD`:

```text
BDD.step(pattern: String, handler: Fn[BDD.Context, List[String], BDD.Context]) -> BDD.Step
BDD.run(steps: List[BDD.Step]) -> Void
BDD.doc_string(ctx: BDD.Context) -> String
BDD.table(ctx: BDD.Context) -> List[List[String]]
BDD.assert(ctx: BDD.Context, condition: Bool, message: String) -> BDD.Context
BDD.set(ctx: BDD.Context, name: String, value: Json) -> BDD.Context
BDD.get(ctx: BDD.Context, name: String) -> Result[Json]
BDD.given_program(ctx: BDD.Context, path: String) -> BDD.Context
BDD.when_line(ctx: BDD.Context, text: String) -> BDD.Context
BDD.when_input(ctx: BDD.Context, text: String) -> BDD.Context
BDD.when_eof(ctx: BDD.Context) -> BDD.Context
BDD.then_line(ctx: BDD.Context, expected: String, timeout_ms: Int) -> BDD.Context
BDD.then_json_line(ctx: BDD.Context, expected: String, timeout_ms: Int) -> BDD.Context
BDD.then_stdin_open(ctx: BDD.Context) -> BDD.Context
BDD.then_exit(ctx: BDD.Context, code: Int, timeout_ms: Int) -> BDD.Context
BDD.then_stdout(ctx: BDD.Context, expected: String) -> BDD.Context
BDD.then_stderr(ctx: BDD.Context, expected: String) -> BDD.Context
```

`BDD.Context` can be named but not built: a context exists only inside a
step. Every call returns the context; use the one it returns. `BDD.run`
never returns; run directly, a step program prints how to run it on stderr
and exits 2. The modules `std/bdd/gherkin`, `std/bdd/match`, `std/test/report`
and `std/test/runner` are internal to `agentica test` and unsupported. See
"`agentica test`" and [`bdd.md`](../bdd.md).

