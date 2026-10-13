# Agentica: grammar and language design

Status: implemented by the interpreter: a Racket front end (`src/`) that compiles to bytecode for the C VM (`vm/`), which runs every program. This document describes what the interpreter accepts; remaining proposals live in [`future/`](future/README.md).

## 1. What we want to validate

Agentica is a language designed so AI agents can write, read, and fix programs easily. The priority is to experiment with the syntax, the rules, and the diagnostics. Performance, concurrency, and the final runtime come later.

The direction is KISS: Ruby-like syntax, static types, local inference, and few ways to express each operation. This specification does not depend on the language the interpreter is written in.

## 2. Design decisions

| Aspect | Rule |
|---|---|
| Syntax | `def`, `struct`, `enum`, `case`, `if`, `while`, `for`, `end`; blocks end with `end` |
| Types | Static, with local inference where it is evident |
| Calls | Parentheses are required |
| Signatures | Explicit return type and required annotations |
| Data | Variables can be reassigned; lists, maps, and structs are immutable |
| Numbers | 64-bit `Int`, no implicit conversions |
| Names | Function names may end in `?` (predicate) or `!` (halting form), independently of whitespace before `(` |
| Library | Builtin modules `Map`, `List`, `String`, `IO`, `System`, `Result`, `JSON`, `Task`, `File`, `Dir`, `Path`, `TCP` and `TLS`; `std/` modules written in Agentica, such as `std/http` |

Generic enums and exhaustive `case` matching are part of the current language. Other proposals remain in [`future/`](future/README.md).

## 3. A core program

```ruby
struct User
  name: String
  age: Int
end

def is_adult(user: User) -> Bool
  return user.age >= 18
end

def main() -> Void
  users = [
    User(name: "Ana", age: 25),
    User(name: "Luis", age: 16)
  ]

  for user in users
    if is_adult(user)
      puts(user.name)
    end
  end
end
```

Blocks end with `end`. Indentation helps reading but does not determine structure. Calls use parentheses, even when they take no arguments; only builtin methods, and module functions without arguments (builtin or reached through an import alias), may drop them (`s.length`, `IO.gets!`, `Util.reset`). Structs are built with named fields; ordinary functions take positional arguments.

The executable starts by calling `main()`. The core has no executable statements at the top level, only declarations. This avoids having two different entry models.

## 4. Lexical conventions

- The file is UTF-8; core identifiers use ASCII characters.
- A comment starts with `#` and ends at the end of the line.
- Names of variables, functions, and fields start with a lowercase letter or `_`.
- Type names start with an uppercase letter.
- Identifiers are case-sensitive.
- Reserved words cannot be used as identifiers.
- Spaces and tabs separate tokens; they have no structural meaning.
- A newline separates statements, except inside `(...)`, `[...]`, and `{...}`.
- CRLF is normalized to LF. A comment does not remove the newline that follows it.
- The lexer emits one `NL` token for each LF or CRLF outside delimiters, including blank and comment lines. Inside a block (`do ... end`, also `if`, `while`, `for`, `def`) that is itself within `(...)`, `[...]` or `{...}`, newlines are emitted too, so a multi-line block can be an argument. The parser ignores extra `NL` tokens between declarations and statements.
- If the file does not end with a newline, the lexer adds one before `EOF`.
- `;`, backslash continuation, and expressions that continue implicitly after an operator are not supported.

So a long expression must be wrapped in parentheses. Inside lists and calls you can use several lines and a trailing comma.

```ruby
total = (
  base +
  extra
)

names = [
  "Ana",
  "Luis",
]
```

Reserved words of the core:

```text
def struct enum case do import export end if elsif else while for in return try
true false nil and or not
```

Future extensions will introduce more reserved words; they are not available.

A trailing `?` or `!` is part of a lowercase `NAME`, regardless of the next parenthesis or whitespace: `contains? (s, part)` is valid. `!` is not a suffix when followed by `=`, so `a!=b` still means `a != b`. By convention, `?` marks a predicate that returns `Bool`, and `!` marks the version that halts the run with an error instead of returning a `Result`. Variables, fields, and parameters cannot have the suffix.

The type and module names `Int`, `Float`, `Bool`, `String`, `Nil`, `Void`, `Process`, `List`, `Map`, `Result`, `Range`, `IO`, and `System` are reserved and cannot be redefined. `ok` and `error` remain NAME tokens, but cannot be declared as user functions, variables, parameters, loop variables, or fields (`CHECK-REDEFINED-NAME`).

### Literals

```ebnf
NAME       = LOWER_OR_UNDERSCORE, { LETTER | DIGIT | "_" }, [ "?" | "!" ] ;
TYPE_NAME  = UPPER, { LETTER | DIGIT | "_" } ;
INTEGER    = DIGIT, { DIGIT } ;
FLOAT      = DIGIT, { DIGIT }, ".", DIGIT, { DIGIT } ;
STRING     = '"', { STRING_CHAR | ESCAPE | INTERPOLATION }, '"' ;
ESCAPE     = "\\", ( '"' | "\\" | "#" | "n" | "r" | "t" ) ;
INTERPOLATION = "#{", expression, "}" ;
```

`LETTER` is `A`–`Z` or `a`–`z`; `DIGIT`, `0`–`9`; `LOWER_OR_UNDERSCORE`, `a`–`z` or `_`; `UPPER`, `A`–`Z`. `STRING_CHAR` is any Unicode character except double quotes, backslash, newlines, and a `#` followed by `{`. `NL` and `EOF` are tokens produced by the lexer.

The minus sign is an operator, not part of the literal. The core has no exponents, alternative bases, numeric separators, or multiline strings.

`"text #{expression} text"` interpolates: the result is a `String`. A `String` value is inserted as is, a `Json` as its JSON text, and any other data value in its `IO.inspect` form (`7`, `2.5`, `true`, `nil`, `[1, 2]`, `Item(name: "a")`); this is the value's `to_s`. A Void call is `CHECK-VOID-VALUE`; a function, task or resource handle has no `to_s` and is `CHECK-TYPE-MISMATCH`. The expression must end on the same line and cannot contain comments; strings, maps and nested interpolation may appear inside it. `\#` writes a literal `#`, so `"\#{x}"` is the text `#{x}`. A `#` not followed by `{` is plain text. `case` patterns and `import` paths take plain string literals only.

## 5. Core EBNF grammar

This is a descriptive grammar: it will be translated to the notation of the chosen tool. `{ X }` means zero or more repetitions, `[ X ]` means optional, and `|` expresses alternatives. Terminals appear in quotes; uppercase names are lexical tokens.

### File and declarations

```ebnf
program          = [ NL ], { declaration }, EOF ;
declaration      = function_decl | struct_decl | enum_decl | import_decl
                 | "export", ( function_decl | struct_decl | enum_decl ) ;
import_decl      = "import", STRING, "as", TYPE_NAME, NL ;

function_decl    = "def", NAME, "(", [ parameters ], ")",
                   "->", type, NL, block, "end", NL ;
parameters       = parameter, { ",", parameter }, [ "," ] ;
parameter        = NAME, ":", type ;

struct_decl      = "struct", TYPE_NAME, NL,
                   { field_decl }, "end", NL ;
field_decl       = NAME, ":", type, NL ;

enum_decl        = "enum", TYPE_NAME, [ type_parameters ], NL,
                   variant_decl, { variant_decl }, "end", NL ;
type_parameters  = "[", TYPE_NAME, { ",", TYPE_NAME }, "]" ;
variant_decl     = TYPE_NAME, [ "(", type, { ",", type }, ")" ], NL ;

qualified_type   = TYPE_NAME, [ ".", TYPE_NAME ] ;
type             = qualified_type, [ "[", type, { ",", type }, "]" ] ;
```

A function, struct or enum declaration (exported or not) must be followed by a blank line before the next declaration; a line with only a comment counts as blank. Otherwise the parser reports `PARSE-MISSING-BLANK-LINE` at the next declaration. Imports may follow each other directly; an import after a declaration also needs the blank line. Other text after a declaration's `end` (a stray `end` or statement) stays `PARSE-TOP-LEVEL-STATEMENT`.

The parser allows type applications such as `List[Int]` and `Option[String]`. The checker restricts applications to supported builtins and declared enums; only enum declarations may declare type parameters. Generic functions and generic structs are not supported.

Struct, enum, and function declarations appear only at the top level. There are no user methods, classes, inheritance, or nested functions; closures are written as blocks.

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
and 5xx are normal responses. Errors are Results. Protocol and limit
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
asked for it, and sends no body for `HEAD`. A handler that returns
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
returns, the run ends whatever the server is doing.

Migration from the builtin `HTTP` module, which roadmap 7i removed: add
`import "std/http" as HTTP`; `HTTP.client()` becomes
`HTTP.client(HTTP.client_options())`; `get`, `post` and `request` return a
whole `HttpResponse`, so `HTTP.text(response.body, t)` becomes
`response.body`; `HTTP.read`, `trailers`, `close_body` and `request_stream`
are gone (send a whole `HTTP.request`; streaming is planned on channels), and
there is no replacement yet for binary bodies: a response body that is not
UTF-8 is now an error; `max_body_bytes` defaults to 1 MiB instead of 64 MiB;
`timeout_ms` now covers the whole response, not only the headers. The
server came back in 20c with handlers that return an `HttpResponse`: a
handler `def handle(request: Request, writer: HttpWriter) -> Void` that
called `HTTP.respond(writer, status, headers, text, timeout_ms)` becomes
`def handle(request: HttpRequest) -> Result[HttpResponse]` that returns
`ok(HttpResponse(status: status, headers: headers, body: text))`;
`HTTP.begin`, `write`, `write_bytes` and `finish` are gone (no streaming
responses, no trailers), and `HttpServerOptions` has `request_timeout_ms`
instead of `header_timeout_ms`. `Request`, `Response`, `HttpBody` and
`HttpWriter` are no longer types.

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
[Function values and BDD](#function-values-and-bdd) and [`bdd.md`](bdd.md).

### Statements and blocks

```ebnf
block            = { statement } ;
statement        = simple_statement, NL
                 | if_statement
                 | case_statement
                 | while_statement
                 | for_statement ;

simple_statement = binding | compound_binding | return_statement | loop_control | expression ;
binding          = NAME, [ ":", type ], "=", expression ;
compound_binding = NAME, ( "+=" | "-=" | "*=" | "/=" | "%=" ), expression ;
return_statement = "return", [ expression ] ;
loop_control     = "break" | "next" ;

if_statement     = "if", expression, NL, block,
                   { "elsif", expression, NL, block },
                   [ "else", NL, block ], "end", NL ;
while_statement  = "while", expression, [ "do" ], NL, block, "end", NL ;
for_statement    = "for", NAME, "in", expression, [ "do" ], NL,
                   block, "end", NL ;
case_statement   = "case", expression, [ "do" ], NL,
                   match_arm, { match_arm }, "end", NL ;
match_arm        = pattern, "->", ( NL, block | simple_statement, NL, block ) ;
pattern          = "_" | literal | "-", INTEGER | "-", FLOAT
                 | qualified_variant, [ "(", pattern_bindings, ")" ]
                 | ( "ok" | "error" ), "(", pattern_bindings, ")" ;
qualified_variant = TYPE_NAME, ".", TYPE_NAME, [ ".", TYPE_NAME ] ;
pattern_bindings = pattern_binding, { ",", pattern_binding } ;
pattern_binding  = NAME | "_" ;
```

Assignments are statements: they do not produce a value. `if`, `while`, and `for` are not expressions either. `x += e` (also `-=`, `*=`, `/=`, `%=`) means `x = x op e`: the target is a plain name that is already visible and assignable, and the checker applies the same rules as the long form. `break` leaves the innermost `while` or `for`; `next` skips to its next iteration. Each stands alone as a statement; `break` and `next` are not reserved words, so a statement that is only one of them is loop control and they can still name variables. They are valid only inside a loop body of the same function or block: a block cannot break or skip its caller's loop, and a function cannot either (`CHECK-LOOP-CONTROL`). Inside a block, `return` leaves the block, like Ruby's `next`. There are no statement modifiers (`break if x`), no `continue`, and no assignment to fields or indexes.

### Expressions and precedence

```ebnf
expression       = or_expr, [ ( ".." | "..." ), or_expr ] ;
or_expr          = and_expr, { ( "or" | "||" ), and_expr } ;
and_expr         = equality_expr, { ( "and" | "&&" ), equality_expr } ;
equality_expr    = comparison_expr,
                   [ ( "==" | "!=" ), comparison_expr ] ;
comparison_expr  = additive_expr,
                   [ ( "<" | "<=" | ">" | ">=" ), additive_expr ] ;
additive_expr    = multiplicative_expr,
                   { ( "+" | "-" ), multiplicative_expr } ;
multiplicative_expr = unary_expr,
                   { ( "*" | "/" | "%" ), unary_expr } ;
unary_expr       = ( "-" | "not" | "!" | "try" ), unary_expr | postfix_expr ;
postfix_expr     = primary, { ".", NAME
                            | ".", NAME, "(", [ arguments ], ")"
                            | "[", expression, "]"
                            | block } ;
block            = "do", [ "|", block_param, { ",", block_param }, "|" ],
                   block_body, "end" ;
block_param      = NAME, [ ":", type ] ;
block_body       = NL, { statement } | simple_statement ;

primary          = literal
                 | "&", ( NAME | TYPE_NAME, ".", NAME )
                 | NAME, [ "(", [ arguments ], ")" ]
                 | TYPE_NAME, ".", TYPE_NAME, ".", TYPE_NAME, [ "(", [ arguments ], ")" ]
                 | TYPE_NAME, ".", TYPE_NAME, "(", [ arguments ], ")"
                 | qualified_type, "(", [ named_arguments ], ")"
                 | qualified_type
                 | list_literal
                 | map_literal
                 | "(", expression, ")" ;

arguments        = expression, { ",", expression }, [ "," ] ;
named_arguments  = named_argument, { ",", named_argument }, [ "," ] ;
named_argument   = NAME, ":", expression ;
list_literal     = "[", [ arguments ], "]" ;
map_literal      = "{", [ map_entry, { ",", map_entry }, [ "," ] ], "}" ;
map_entry        = expression, ":", expression ;
literal          = INTEGER | FLOAT | STRING | "true" | "false" | "nil" ;
```

Calls are to named functions or function values via `.call(...)`; arbitrary user methods are not supported. `&name` references a declared top-level function without capturing variables; a block (see "Blocks and closures") captures them. `call` is not a reserved word. `user.name`, `users[0]`, and `find_user(1).name` also fit the grammar. A bare `gets` or `gets!` is a call with no arguments. A bare `qualified_type` of the form `Enum.Variant`, where `Enum` is an enum of the same file, is that nullary variant; `M.Enum.Variant` without parentheses is one through an import alias. `Result.Ok(...)` and `Result.Err(...)` are the `ok`/`error` calls. `puts`, `print`, `gets` and `gets!` cannot name variables, parameters, loop variables or pattern bindings (`CHECK-REDEFINED-NAME`).

`TYPE_NAME, ".", NAME, "(" … ")"` calls a builtin module function (`Map.put(...)`) or an exported function through an import alias. Without arguments the parentheses may be dropped: `IO.gets!` is `IO.gets!()`, and `while !IO.eof? do` reads like Ruby. This holds for imported functions too: `f = Util.helper` calls `helper`; write `&Util.helper` for the function value.

`a..b` and `a...b` build a `Range` (see "Ranges"). They have the lowest precedence and do not chain: `0...n + 1` is `0...(n + 1)`, and `1..2..3` is `PARSE-UNEXPECTED-TOKEN` at the second operator. `x = 0...n`, `f(0..n)` and `for i in 0...n` need no parentheses; a method call does: `(1..5).to_a`. A line that ends in `..` or `...` does not continue on the next line. `1..5` lexes as two integers around `..`, never as a Float.

`and` and `or` short-circuit. Additions, subtractions, multiplications, divisions, and modulos group from left to right. Comparisons and equality checks do not chain: `a < b < c` is invalid; write `a < b and b < c`.

| Precedence, high to low | Operations |
|---|---|
| 1 | Named call, field `.`, index `[]`, grouping |
| 2 | Unary `-`, `not` / `!`, `try` |
| 3 | `*`, `/`, `%` |
| 4 | `+`, `-` |
| 5 | `<`, `<=`, `>`, `>=` |
| 6 | `==`, `!=` |
| 7 | `and` / `&&` |
| 8 | `or` / `\|\|` |
| 9 | `..`, `...` (not associative) |

`not` has high precedence: to negate a comparison, write `not (age >= 18)`.

## 6. Minimal semantic rules

The grammar determines what can be written. The following rules determine which programs are valid and how they run. They are the rules the interpreter implements.

### Types and inference

| Type | Rule |
|---|---|
| `Int` | Signed 64-bit integer; overflow is a runtime error |
| `Float` | IEEE 754 binary64 |
| `Bool` | Only `true` and `false`; there is no truthiness |
| `String` | Unicode text; concatenation with `+` |
| `Nil` | A single data value, `nil` |
| `Void` | Completion without a usable value; no literal |
| `List[T]` | Homogeneous, immutable list; `Int` indexes, from zero |
| `Map[K, V]` | Homogeneous, immutable dictionary; the key `K` is `Int` or `String`; keeps insertion order |
| `Result[T]` | Exactly one payload type; successful `ok(value)` or String-valued `error(message)` |
| `Json` | Opaque JSON value, accessed through the `JSON` module |
| `Range` | Immutable range of `Int` values: `a..b` includes `b`, `a...b` excludes it |
| `Fn[A, ..., R]` | Function value (`&name` or a block); final type is its return, preceding types are parameters |
| `Task[R]` | Opaque lightweight task with exactly one result type |
| `Enum[T, ...]` | User-declared nominal sum type; type parameters are declared on the enum |
| Network handles | Opaque `Socket`, `Listener`, `HttpClient`, `HttpServer` |
| Builtin records | `Header`, `HttpRequest`, `HttpResponse`, `HttpClientOptions`, `HttpServerOptions` |
| Declared struct | Nominal type, typed and immutable fields |

Parameters and the return type of functions require an annotation. Local variables can be inferred from the initializer:

```ruby
count = 3
names: List[String] = []
```

An empty list needs an expected type, which can come from an annotation, a parameter, a field, or the return type of a function. A non-empty list must have elements of the same type. There is no implicit numeric conversion and no dynamic `Any` type.

`Nil` is not a nullable wildcard: `name: String = nil` is invalid. Define an enum such as `Option[T]` when an optional value is needed.

### Operators

- `+`, `-`, `*`, and `/` accept two operands of the same numeric type. Also, `+` concatenates two `String` values.
- Integer division truncates toward zero. `%` accepts only integers and is defined by `a = (a / b) * b + (a % b)`.
- Dividing by zero is a runtime error, also for `Float`. Integer operations that do not fit in `Int` produce an error.
- The ordering operators accept only two numbers of the same type.
- `==` and `!=` accept values of the same primitive type, or two `Range` values: two ranges are equal when start, end and kind (`..` or `...`) match. The core has no list or struct equality.
- `..` and `...` accept two `Int` values and give a `Range`; anything else is `CHECK-TYPE-MISMATCH`.
- `and`, `or`, and `not` accept only `Bool`. `&&`, `||`, and `!` are the same operators with the same precedence. A `!` directly after a name belongs to the name (`read!`), and `!=` is inequality; a standalone `!` is `not`.
- There is no user-defined operator overloading.

Expressions, arguments, and constructor fields are evaluated from left to right. A float comparison follows IEEE 754; in particular, a NaN is not equal to itself.

### Variables and scope

The first assignment introduces a variable in the current scope. A later assignment changes its value without changing its type. An annotation can appear only when the variable is introduced.

Each function and each control block introduces a lexical scope. A visible variable cannot be shadowed by another with the same name. An assignment without an annotation updates the visible variable if it already exists; otherwise it introduces a local in the current block.

Parameters and the `for` variable are already-initialized bindings. The `for` variable is local to the body and cannot be reassigned. Variables created in a block are not visible after its `end`.

```ruby
count = 0
while count < 3
  puts("hello")
  count = count + 1
end
```


### Void completion

`Void` has no literal or usable payload. It is permitted as a function return, the final type of `Fn`, or the completion type of `Result`/`Task`. Bare Void variables, parameters, fields, List elements, and Map values are `CHECK-VOID-TYPE`. Wrappers such as `List[Result[Void]]` are valid data.

A Void call may be a statement or be forwarded from a Void function with return another_void_call(). Assignment, argument passing, construction, operators, and inspection of bare completion fail with CHECK-VOID-VALUE. The same restriction applies to Result.unwrap!(Result[Void]), Task.await(Task[Void]), and successful try on Result[Void].

ok() infers Result[Void] and prints ok(); ok(nil) is Result[Nil] and prints ok(nil). Result[Void] functions explicitly return ok() or error(message); try still requires an enclosing Result-returning function. Result.unwrap_or needs a data fallback and cannot operate on Result[Void].

### Functions and entry point

- Functions can be called before their declaration and can be recursive.
- There is no overloading, default values, or named arguments in ordinary functions.
- A function with a return type other than `Void` must return on every reachable path. In the initial checker, a loop does not by itself guarantee a return.
- The last expression does not return implicitly. Exhaustive `case` is a statement; a non-`Void` function may use it to return only when every arm returns.
- `return` without a value completes a `Void` function. Functions returning `Nil` explicitly use `return nil`.
- Reaching the end of a `-> Void` function completes without a value.
- An executable must declare exactly one `main() -> Void` function with no parameters.

### Enums and pattern matching

Enums are nominal sum types and may declare type parameters. Variant names are qualified by the enum; payloads are positional, and a nullary variant is constructed with or without empty parentheses (`Command.Show` or `Command.Show()`). Constructor type parameters are inferred from payloads and the expected enum type; unresolved or conflicting parameters are errors. Imported enum variants use the import alias plus enum and variant names.

`case value ... end` is a statement; a `do` after the value is allowed but not needed. An arm may put one simple statement on the arrow line (`1 -> puts("one")`); more lines of the same arm may follow. Patterns are primitive literals, `_`, `ok(...)`/`error(...)` for Results, or a qualified enum variant with one direct binding or `_` discard per payload position. Bindings are local to the arm; nested patterns and guards are not supported. Enum values require every declared variant unless there is a catch-all `_`. `Result[T]` can be matched as `Result.Ok(value)` / `Result.Err(message)`; use `Result.Ok(_)` to discard a payload, including the `Void` success payload. Every non-enum case, including `Bool` and `Nil`, requires `_`. A catch-all is last; duplicate and unreachable arms are rejected. The checker reports enum inference failures as `CHECK-ENUM-TYPE-INFERENCE`, invalid patterns as `CHECK-PATTERN-TYPE`, missing coverage as `CHECK-NON-EXHAUSTIVE-CASE`, and covered arms as `CHECK-UNREACHABLE-CASE-ARM`.

```ruby
enum Option[T]
  Some(T)
  None
end

def display(option: Option[Int]) -> Void
  case option
    Option.Some(item) -> puts(String.from_int(item))
    Option.None -> puts("empty")
  end
end
```

### Structs and lists

All fields of a constructor are required and given exactly once. The order of named fields is free. There are no default fields and no extra fields.

```ruby
user = User(age: 25, name: "Ana")
```

List indexes must be between zero and length minus one; a negative or out-of-range index is an error. Indexing costs O(n) in this interpreter; prefer `for` for traversal rather than repeated indexed access. `for` iterates over `List[T]` in order, and over a `Range` (next section). Slices and string indexing are not supported in the core.

### Ranges

`a..b` is the range of `Int` values from `a` to `b`, both included; `a...b` excludes `b`, as in Ruby. Both operands are `Int`. The result has the builtin type `Range`, a small immutable value (start, end and kind); it never holds a list.

```ruby
for i in 0...3 do
  puts(i)          # 0, 1, 2
end

3.times do |i|
  puts(i)          # 0, 1, 2
end

evens = (0..10).to_a.filter do |n|
  n % 2 == 0
end
```

- `for x in range` yields each `Int` in order without building a list. A range whose end is before its start is empty; there is no reverse iteration (use `downto`, or `List.reverse` on `to_a`). Iteration up to the largest `Int` does not overflow. Each iteration costs one step (even with an empty body), plus its body. The range is evaluated once, so assigning to its variable in the body does not change the loop.
- `Range` functions, also methods (`(1..5).size`):

  | Function | Result |
  |---|---|
  | `Range.size(r: Range) -> Int` | the number of values; `RUNTIME-INTEGER-OVERFLOW` at the receiver when it does not fit in `Int` (`(0..9223372036854775807).size`) |
  | `Range.to_a(r: Range) -> List[Int]` | the values in order; above 1048576 values, `RUNTIME-INVALID-COUNT` at the receiver |
  | `Range.include?(r: Range, value: Int) -> Bool` | whether the value is in the range |
  | `Range.each(r: Range, f: Fn[Int, Void]) -> Void` | calls `f` on each value in order |
  | `Range.first(r: Range) -> Result[Int]`, `Range.last(r: Range) -> Result[Int]` | the first and last included values; `error("the range is empty")` for an empty range. Unlike Ruby, `(1...5).last` is `ok(4)` |

- `Int` methods for loops, all returning `Void`: `n.times(f)` calls `f` with `0` to `n - 1` (nothing when `n <= 0`); `a.upto(b, f)` with `a` up to `b` (nothing when `b < a`); `a.downto(b, f)` with `a` down to `b` (nothing when `b > a`). `f` is `Fn[Int, Void]`, usually a block. They are also module functions: `Int.times(n, f)`, `Int.upto(a, b, f)`, `Int.downto(a, b, f)`. Each call of `f` (and `Range.each`'s) costs one step plus the block. A negative literal receiver needs parentheses: `-5.times do ... end` is `-(5.times ...)`, a `CHECK-VOID-VALUE` whose help says to write `(-5).times`.
- Text form: `1..5` and `1...5`, as Ruby's `inspect`; `to_s`, interpolation and `IO.inspect` all show it. Ranges have `==` (start, end and kind match). They are not JSON-encodable and cannot be `Map` keys.
- Ranges of `String` or `Float` and `step` are not supported.

### Maps

`Map[K, V]` associates keys with values. The key `K` can only be `Int` or `String`; `V` can be any type. `Map` takes exactly two type arguments.

```ruby
stock: Map[String, Int] = {"apple": 3, "pear": 0}
apples = stock["apple"]
more = Map.put(stock, "kiwi", 7)
```

- A literal uses braces and `key: value`; it allows several lines and a trailing comma. An empty `{}` needs an expected type, like `[]`; without it the diagnostic is `CHECK-EMPTY-MAP-TYPE` (`CHECK-EMPTY-LIST-TYPE` is only for `[]`).
- `m[key]` returns the value. The key must have type `K`. A missing key is a runtime error.
- If a literal repeats a key, the last value wins; the key keeps its first-insertion position. Replacing a key with `Map.put` also preserves its position.
- Maps are immutable, like lists: there is no `m[key] = value`. `Map.put` returns a new map and leaves the original intact.
- There is no map equality and no `for` over a map; iterate with `Map.keys`, which returns the keys in insertion order.
- The VM keeps a map as a persistent hash array mapped trie (a HAMT, 32-way): lookup, `Map.has_key?`, and `Map.put` are effectively constant-time in map size (technically O(log32 n), excluding key hashing/comparison). `Map.size` is O(1); `Map.keys` is O(n). Updates share unchanged storage rather than copying the whole map.

### Methods on builtin types

`receiver.name(args)` calls a builtin function with the receiver as its first argument. The checker picks the module from the receiver's static type, so there is no dynamic dispatch:

| Receiver type | Module |
|---|---|
| `String` | `String` |
| `List[T]` | `List` |
| `Map[K, V]` | `Map` |
| `Float` | `Float` |
| `Result[T]` | `Result` |
| `Json` | `JSON` |
| `Range` | `Range` |
| `Int` | `Int` (`times`, `upto`, `downto`) and aliases |

Only functions whose first parameter has the receiver's type are methods: `s.trim` is `String.trim(s)`, `xs.map(&f)` is `List.map(xs, &f)`, but `"a".from_int` is not a method. Without parentheses, `receiver.name` on a non-struct value is a method with no arguments: `s.length`, `xs.size`, `r.ok?`. On a struct, `.name` is field access; structs and enums have no methods, and user functions cannot be called as methods. `.call(...)` invokes a function value.

Ruby aliases:

| Receiver | Alias | Same as |
|---|---|---|
| `String` | `size` | `String.length` |
| `String` | `to_i`, `to_i!` | `String.to_int` (Result), `String.to_int!` |
| `String` | `to_f`, `to_f!` | `String.to_float` (Result), `String.to_float!` |
| `String` | `strip` | `String.trim` |
| `String` | `include?`, `start_with?`, `end_with?` | `String.contains?`, `String.starts_with?`, `String.ends_with?` |
| `String` | `to_s` | the same string |
| `List` | `length` | `List.size` |
| `List` | `push` | `List.append` |
| `List[String]` | `join` | `String.join` |
| `Int` | `to_s`, `to_f` | `String.from_int`, `Float.from_int` |
| `Float` | `to_s` | `String.from_float` |
| `Float` | `to_i`, `to_i!` | `Float.to_int` (Result), `Float.to_int!` |
| any data value | `to_s` | the text `"#{x}"` gives |
| any data value | `inspect` | the text `IO.inspect(x)` prints |

Unlike Ruby, `"abc".to_i` returns `Result[Int]` (an error here), not `0`; `to_i!` halts on bad text. An unknown method is `CHECK-UNKNOWN-METHOD`, with a suggestion or the list of that type's methods.

Every data value has `to_s`: numbers, `Bool`, `String`, `nil`, `Json`, ranges, and lists, maps, Results, structs and enums made of those. `x.to_s` is the text `"#{x}"` gives: a `String` as is, a `Json` as its JSON text, and anything else in its `IO.inspect` form (`true`, `nil`, `[1, 2]`, `ok(3)`, `Item(name: "a")`, `Shape.Box(1, 2)`). `puts(x)`, `print(x)` and `IO.warn(x)` take any value with `to_s` and write that text. Only a top-level `Json` becomes JSON text; inside a list or Result it shows as `<Json>`, so `puts(JSON.parse(s))` prints `ok(<Json>)`. Functions, tasks and resource handles (sockets, files, processes, HTTP values) have no `to_s`: printing or interpolating one is `CHECK-TYPE-MISMATCH`, and `.to_s` on one is `CHECK-UNKNOWN-METHOD`. A struct field named `to_s` is read as the field. Unlike Ruby, `nil.to_s` is `"nil"`, and `puts([1, 2])` writes `[1, 2]` on one line.

`x.inspect` returns the `IO.inspect` form as a `String`, for the same types as `to_s`. It differs from `to_s` only for strings, which keep their quotes (`"a".inspect` is `"a"` with the quote characters), and for `Json`, which gives `<Json>`. Use `IO.inspect(x)` to print that form and get `x` back. The debug form is for display: strings use the host's escapes, so it is not guaranteed to be valid Agentica source (`"a\#{b}".inspect` shows `#{` without the backslash).

Values are immutable, so a method never changes its receiver: `xs.push(2)` returns a new list. Calling a builtin without effects and ignoring a non-`Void` result is `CHECK-UNUSED-VALUE`; write `xs = xs.push(2)`. Functions ending in `!` are exempt, since they can halt, and so are builtins that take a function (`xs.map(&save)`), since the function may have effects. A negative literal receiver needs parentheses: `(-5).to_s`, because `-5.to_s` is `-(5.to_s)`.

```ruby
words = line.strip.split(" ")
puts(words.join(","))
first = words[0].to_i!
xs = xs.push(first)
```

### Minimal builtin functions

```text
puts(value: T) -> Void        # T has to_s
print(value: T) -> Void       # no newline
gets() -> Result[String]
gets!() -> String
```

`puts` writes the text and a newline; `print` writes it without one. `gets` and `gets!` are `IO.gets` and `IO.gets!`, and like them they may drop their parentheses (`line = gets!.strip`). These names are reserved and cannot be redefined.

To work with maps and lists there are two builtin modules, `Map` and `List`, called as `Module.function(...)`. Their functions are generic, so the checker treats them specially. The names `Map` and `List` are reserved and cannot be redefined.

```text
Map.has_key?(map: Map[K, V], key: K) -> Bool
Map.keys(map: Map[K, V]) -> List[K]
Map.size(map: Map[K, V]) -> Int
Map.put(map: Map[K, V], key: K, value: V) -> Map[K, V]
Map.get(map: Map[K, V], key: K) -> Result[V]
Map.get(map: Map[K, V], key: K, default: V) -> V
Map.delete(map: Map[K, V], key: K) -> Map[K, V]
Map.values(map: Map[K, V]) -> List[V]
List.size(list: List[T]) -> Int
List.append(list: List[T], value: T) -> List[T]
List.set(list: List[T], index: Int, value: T) -> List[T]
List.repeat(value: T, count: Int) -> List[T]
List.reverse(list: List[T]) -> List[T]
List.map(list: List[A], f: Fn[A, B]) -> List[B]
List.filter(list: List[A], f: Fn[A, Bool]) -> List[A]
List.reduce(list: List[A], initial: B, f: Fn[B, A, B]) -> B
List.concat(a: List[T], b: List[T]) -> List[T]
List.take(list: List[T], count: Int) -> List[T]
List.drop(list: List[T], count: Int) -> List[T]
List.at(list: List[T], index: Int) -> T
List.sort(list: List[T]) -> List[T]
List.sort_by(list: List[A], key: Fn[A, K]) -> List[A]
List.each(list: List[A], f: Fn[A, Void]) -> Void
List.any?(list: List[A], f: Fn[A, Bool]) -> Bool
List.all?(list: List[A], f: Fn[A, Bool]) -> Bool
```

`List.map` transforms each element; `List.filter` keeps elements whose predicate returns true. Both preserve order and inputs. `List.reduce` folds left, calling `f(accumulator, item)` with the initial value first; an empty list returns the initial value. Callbacks run exactly once per element, left to right, and use the caller's execution budget and error handling. Callback parameter and return types must match exactly; map callbacks must return data, not Void. Callback signatures (`&name`, a `Fn` variable, or a block with annotated parameters such as `do |x: Int|`) infer empty input lists and empty reduce initial values. All three operations cost O(n), excluding callback work. Pass a block, a named function reference (`&name`) or a function-valued variable.

`List.concat` joins lists of the same element type and costs O(length of the first list). `List.take` returns the first count elements; `List.drop` removes them. Counts must be nonnegative (otherwise RUNTIME-INVALID-COUNT at the count argument); counts greater than length return the whole list or an empty list, respectively. Both cost O(n) with the current list representation. `List.at` is zero-based, costs O(n), and reports RUNTIME-INDEX-OUT-OF-RANGE at the index argument for negative or out-of-range indexes, like indexing syntax.

`List.sort` sorts in ascending order; its elements must be `Int`, `Float`, or `String`. `List.sort_by` sorts by the key its function returns, and the key must be `Int`, `Float`, or `String`. The key function runs once per element, left to right. Both sorts are stable: equal elements keep their order. Strings compare by Unicode code point, so `"B"` comes before `"a"`. Float NaN goes last. Other element or key types are `CHECK-TYPE-MISMATCH`. Both cost O(n log n), plus the key calls, and preserve the input.

Collection operations preserve their inputs. `List.append`, `List.set`, and `List.reverse` cost O(n); repeated appends can cost O(n²). `List.repeat` costs O(count), accepts 0..1048576, and returns an empty typed list for zero. Invalid counts halt with `RUNTIME-INVALID-COUNT` at the count argument. `List.set` uses zero-based indexes and halts with `RUNTIME-INDEX-OUT-OF-RANGE` at the index argument if it is negative or outside the list.

`Map.get` with two arguments returns `ok(value)` for a present key and `error(message)` for an absent key. With three arguments it returns the present value or the default; the default is always evaluated, even when the key exists. False and nil are present values. `Map.delete` ignores absent keys, preserves the order of remaining keys, and costs O(n) to maintain that order. A deleted key reinserted with `Map.put` goes to the end. `Map.values` follows `Map.keys` order and costs O(n). Expected types flow into these operations for contextual empty collections and Results; without enough context the existing empty-collection diagnostics apply.

The `String` module works on text. `String.length` and `String.slice` count Unicode characters, not bytes; a `slice` out of range is a runtime error. With a non-empty `sep`, `String.split(s, sep)` keeps every part, even empty ones at the ends or between two separators, so `String.join(String.split(s, sep), sep)` gives back `s`; `String.split("", sep)` is `[""]`. `String.split(s, "")` returns a list with one Unicode character per element. The conversions `String.to_int!` and `String.to_float!` accept decimal numbers with an optional sign; `to_int!` fails with `RUNTIME-INVALID-NUMBER` if the text is not a decimal integer and with `RUNTIME-INTEGER-OVERFLOW` if it is outside the range of `Int`, while `to_float!` rejects text that is not a real decimal with `RUNTIME-INVALID-NUMBER`.

```text
String.length(s: String) -> Int
String.upcase(s: String) -> String
String.downcase(s: String) -> String
String.trim(s: String) -> String
String.split(s: String, separator: String) -> List[String]
String.join(parts: List[String], separator: String) -> String
String.contains?(s: String, part: String) -> Bool
String.starts_with?(s: String, prefix: String) -> Bool
String.ends_with?(s: String, suffix: String) -> Bool
String.replace(s: String, from: String, to: String) -> String
String.slice(s: String, start: Int, length: Int) -> String
String.index_of(s: String, part: String) -> Result[Int]
String.at(s: String, index: Int) -> String
String.reverse(s: String) -> String
String.code(c: String) -> Int
String.from_code(n: Int) -> String
String.from_int(n: Int) -> String
String.from_float(x: Float) -> String
String.from_bytes(data: List[Int]) -> Result[String]
String.to_int(s: String) -> Result[Int]
String.to_float(s: String) -> Result[Float]
String.to_int!(s: String) -> Int
String.to_float!(s: String) -> Float
Float.from_int(n: Int) -> Float
Float.to_int(x: Float) -> Result[Int]
Float.to_int!(x: Float) -> Int
```

`String.index_of` returns the character index of the first match, `ok(0)` for an empty part, and an error when the part is absent. `String.at` reads one character at a zero-based index and halts with `RUNTIME-INDEX-OUT-OF-RANGE` at the index argument outside the string. `String.reverse` reverses Unicode characters. `String.code` returns the code point of a one-character string; `String.from_code` builds one from a Unicode scalar value (0..0x10FFFF, without surrogates). Both halt with `RUNTIME-INVALID-CHARACTER` at their argument on other input. `Float.from_int` converts to the nearest Float. `Float.to_int` truncates toward zero; NaN and infinity are errors, and results outside `Int` are errors. `Float.to_int!` halts instead, with `RUNTIME-INVALID-NUMBER` or `RUNTIME-INTEGER-OVERFLOW`.

The `IO` module writes and reads through the standard ports; `IO.warn` writes to standard error. `IO.inspect` prints any value in a stable debug form and returns it. `IO.gets` returns `ok(line)` without its terminator (LF, CR, or CRLF), or an error value at EOF. A blank line is `ok("")`, not EOF. `IO.gets!` returns the line directly and halts with `RUNTIME-END-OF-INPUT` at EOF; `IO.eof?` lets you check first. The `System` module exposes the program arguments and ends the run with a code.

```text
IO.puts(value: T) -> Void
IO.print(value: T) -> Void
IO.warn(value: T) -> Void
IO.inspect(value: T) -> T
IO.gets() -> Result[String]
IO.gets!() -> String
IO.read() -> String
IO.read_bytes(count: Int) -> Result[List[Int]]
IO.flush() -> Void
IO.eof?() -> Bool
System.args() -> List[String]
System.exit(code: Int) -> Void
Time.now_ms() -> Int
Time.monotonic_ms() -> Int
Random.int(min: Int, max: Int) -> Int
Random.float() -> Float
```

`Time.now_ms()` reads wall-clock time as milliseconds since the Unix epoch; it can jump when the system clock changes. `Time.monotonic_ms()` counts milliseconds from an arbitrary origin and never goes backward; subtract two readings to measure durations. `Random.int(min, max)` returns a uniform `Int` in `min .. max`, both inclusive, over the whole `Int` range; `min > max` halts with `RUNTIME-INVALID-RANGE` at the call. `Random.float()` returns a uniform `Float` in `0.0` up to, but not including, `1.0`. Each run has its own generator. Without `--seed` it is seeded from operating-system randomness, so runs differ. `agentica --seed N program.agc` (N in `0 .. 2147483647`, otherwise exit 2) repeats the same sequence for the same program and input. `agentica --seed N test` passes the seed to every scenario's step program and to the programs under test. Each task has its own generator: the main task is seeded from `--seed`, and each spawn takes one draw from the parent's generator to seed the child, so a task's values depend only on its own calls and on how many tasks its parent spawned before it. With `--seed`, only each task's own values repeat on the VM: how tasks interleave can still depend on timer and thread-pool timing (sleeps, file and stdin reads), even on one scheduler, so a multi-task run as a whole is not repeatable. The generator is not suitable for secrets. `Time` and `Random` are reserved builtin module names: no declaration or import alias may use them.

- `IO.read()` drains text until EOF; do not use it to read one message from a peer that keeps stdin open. `IO.gets()` reads a line instead. Both read stdin through the VM's own input buffer. On Linux it is filled by reads on the I/O thread pool, so other tasks keep running while one waits for input; on other platforms the read blocks.
- `IO.read_bytes(count)` waits for exactly `count` bytes or EOF and returns a list of integers in `0 .. 255`, with no UTF-8 decoding. A short final read succeeds; EOF before any bytes is `ok([])`. Zero returns `ok([])` without consuming input, even before EOF. Counts must be `0 .. 1048576` (1 MiB per call), bounding eager allocation; invalid counts return an error without consuming input. Input-port failures also return an error. Larger streams can be processed in multiple reads.
- `String.from_bytes(data)` checks every integer is `0 .. 255`, then decodes UTF-8 strictly. Empty bytes produce `ok("")`; invalid, overlong, surrogate, or incomplete sequences return an error, never replacement characters. Byte reads may split a multibyte character; decode only when its complete bytes are available. Existing text and byte readers share one port; text readers should only be used at a complete character boundary.
- `IO.eof?()` peeks at the next byte without consuming it. It can block while awaiting data or EOF, but never waits to decode a whole UTF-8 character. It is not a readiness poll. Reads have no timeout, and the step budget cannot interrupt blocking I/O.
- `IO.flush()` flushes stdout and returns nil; it does not close the stream or flush stderr. Output functions do not automatically flush. For interactive stdio protocols, write one compact JSON message per line and flush after each response; logs go to stderr with `IO.warn`.

### Result and propagation

```text
ok(value: T) -> Result[T]
ok() -> Result[Void]
error(message: String) -> Result[T]
Result.ok?(r: Result[T]) -> Bool
Result.unwrap!(r: Result[T]) -> T
Result.unwrap_or(r: Result[T], default: T) -> T
Result.message(r: Result[T]) -> String
```

- `Result.Ok(x)`, `Result.Ok()` and `Result.Err(m)` are the same as `ok(x)`, `ok()` and `error(m)`. In `case`, the patterns `ok(v)` and `error(m)` are the same as `Result.Ok(v)` and `Result.Err(m)`.
- `Result[T]` is builtin, not a user enum. It can nest and contain any valid payload type. Results have no equality, fields, or indexing.
- `ok(1)` infers `Result[Int]`. An expected `Result[T]` checks the payload against `T`, including empty lists/maps.
- `error("bad")` needs an expected Result type from an annotation, existing binding, parameter, field, return, or typed container element. Otherwise it is `CHECK-RESULT-TYPE`; no success type is guessed.
- `Result.unwrap!` passes its expected output type `T` to the operand as `Result[T]`. On an error it halts with `RUNTIME-UNWRAP-ERROR`, the stored message, and the unwrap call span.
- `Result.unwrap_or` uses the expected output type, or infers it from the default. Both arguments run eagerly, left to right, even for a success.
- `Result.ok?` and `Result.message` need an argument whose Result type is known. A success's message is `""`. `ok(false)` and `ok(nil)` are successes.
- Container inference still uses the first element: `[ok(1), error("bad")]` infers, but the reverse order needs an annotation.
- Non-bang String conversions use the same signed-decimal syntax and integer bounds as bang forms, but invalid text/overflow return errors rather than halting. Unrelated runtime failures are not converted to Results.
- `IO.inspect` prints recursive `ok(...)` / `error(...)` forms and returns its argument. Error values do not print diagnostics or change the run's exit code.
- `try` has unary precedence: it evaluates one `Result[T]` operand once and produces `T` on success, or returns its error from the current function. Only a function returning `Result[...]` may use it (`CHECK-TRY-CONTEXT` otherwise). Operand and enclosing success types may differ. An expected expression type `T` supplies `Result[T]` to the operand; the enclosing return type alone does not infer it. A success still needs an explicit return from the function.

```ruby
def read_age(text: String) -> Result[Int]
  age = try String.to_int(text)
  return ok(age)
end
```

### JSON

`Json` and `JSON` are reserved builtin names. A `Json` is opaque: it has no constructor, equality, fields, or direct indexing. `IO.inspect` prints `<Json>` and `j.inspect` gives `"<Json>"` without exposing its contents. `j.to_s`, `"#{j}"`, `puts(j)` and `JSON.encode(j)` give its JSON text.

```text
JSON.object(fields: Map[String, Json]) -> Json
JSON.array(items: List[Json]) -> Json
JSON.from(value: T) -> Json
JSON.null() -> Json
JSON.null?(value: Json) -> Bool
JSON.schema(type: T) -> Json
JSON.decode(s: String, type: T) -> Result[T]
JSON.parse(s: String) -> Result[Json]
JSON.encode(value: T) -> String
JSON.get(j: Json, key: String) -> Result[Json]
JSON.at(j: Json, index: Int) -> Result[Json]
JSON.string(j: Json) -> Result[String]
JSON.int(j: Json) -> Result[Int]
JSON.float(j: Json) -> Result[Float]
JSON.bool(j: Json) -> Result[Bool]
JSON.list(j: Json) -> Result[List[Json]]
```


JSON builders create Json values directly: object takes Map[String, Json],
array takes List[Json], and from accepts the same recursively encodable data
as JSON.encode. Non-finite Float conversion halts with RUNTIME-JSON-ENCODE.
Null and false remain distinct, as do empty objects and arrays.

JSON.schema(User) accepts the same named structs as JSON.decode and returns
an object schema with properties and required fields. Int schemas specify
signed 64-bit bounds; lists use items and String-keyed maps use
additionalProperties. Nested/recursive structs use $defs/$ref. Extra struct
keys remain allowed, matching decoding. Schema is a Json value, not text.

`JSON.decode(text, User)` returns Result[User]. Its second argument is a named
struct type, not a runtime value; bare type names are valid only for decode/schema.
Fields may contain Int, Float, Bool, String, lists, String-keyed maps, and nested
or recursive structs. Unsupported nested types give CHECK-NOT-DECODABLE.
Malformed JSON, missing fields, wrong types, Int overflow, or non-finite Float
conversion return errors with field/index paths. Extra object keys are ignored.
Integer JSON values may decode as Float; decimal/exponent values never decode
as Int. Maps decoded from JSON use sorted key order.


- `JSON.parse` reads exactly one JSON value, with optional surrounding JSON whitespace (space, tab, CR, LF). Empty input, malformed JSON, trailing content, invalid Unicode escapes, raw control characters in strings, or non-finite parsed numbers return an error. A repeated object key keeps the last value.
- `JSON.get` requires an object and a present key; `JSON.at` requires an array and an index in `0 .. length - 1`. Missing keys, bad indexes, and wrong kinds return errors, not runtime diagnostics. JSON `false` and `null` are valid present values.
- String and Bool extraction require the exact JSON kind. `JSON.int` requires an integer within signed 64-bit bounds; a decimal or exponent form is not an Int, even if mathematically integral. `JSON.float` accepts an integer or decimal/exponent number and converts it to finite binary64, with normal rounding; conversion overflow returns an error. Parsed integers may exceed Int bounds until extracted.
- `JSON.list` returns an array's elements as opaque Json values in order; heterogeneous arrays are valid. JSON null stays inside Json, distinct from a Bool or Nil extraction (there is no null extractor yet).
- `JSON.encode` accepts Int, Float, Bool, String, Nil (as `null`), Json, lists, String-keyed maps, and structs whose nested types are also encodable. Results and Int-keyed maps, including empty or nested ones, are `CHECK-NOT-ENCODABLE` errors. Untyped empty containers still need an annotation.
- Encoding produces compact JSON, preserving struct declaration order and map insertion order. A parsed object holds each key once (a repeated key keeps its last value) and encodes with its keys sorted by their UTF-8 bytes, so `JSON.encode(JSON.parse(x))` is canonical: two texts that differ only in whitespace, key order or repeated keys give the same text, while arrays keep their order and numbers their kind (`1` and `1.0` stay different). Comparing canonical texts therefore compares JSON values. Objects built with `JSON.object` or `JSON.from` have no fixed order. Non-finite Floats halt with `RUNTIME-JSON-ENCODE` at the encode call; they are never silently replaced by null. The VM's `vm/json.c` parses and encodes JSON.
- Typed struct decoding, JSON builders, and schemas are later phases. See `examples/json.agc` for encoding, extraction, and `try`.

### Function values and BDD

`Fn` is a reserved builtin name. `f: Fn[Int, Int] = &double` refers to a declared function with exactly those parameter and return types; `f.call(21)` invokes it. References can travel through lists, maps, parameters, returns, and fields. A bare function name remains invalid as a value. Functions have no equality, field access, indexing, or JSON encoding; `IO.inspect` prints `<Fn>`.

`agentica test [PATH...] [--steps FILE] [--only TEXT]` runs `.feature` specifications and `*_test.agc` unit test files (see `Test` below) in one report and gives the verdict as its exit code. With no paths it searches `specs/` and `test/`, skipping a folder that does not exist; `--only TEXT` keeps the tests and scenarios whose name contains `TEXT`. Each test file is compiled on its own (a front-end error is a file error of that file) and runs in its own child VM, one task per test, with 30 seconds per test (RUNTIME-TEST-TIMEOUT, and the rest of the file is not executed). A failed test shows the stdout it printed, at most the last 64 Ki characters; a passed test's output is dropped. The run always has a seed: `--seed N`, or one drawn and shown in the report. BDD is the standard module `std/bdd`, written in Agentica (`import "std/bdd" as BDD`; `BDD` is not reserved, and a `BDD.` call without the import is `CHECK-UNKNOWN-NAME` with that import as its help). The one `--steps` program is a normal program whose `main` builds its steps with `BDD.step(pattern: String, handler: Fn[BDD.Context, List[String], BDD.Context]) -> BDD.Step` and passes the list to `BDD.run(steps: List[BDD.Step]) -> Void`. Every scenario runs in its own child VM, so a step that crashes, exits or loops fails only its scenario; failure stops its remaining steps and execution continues with the next scenario. Every BDD call takes the scenario's context first and returns it. See [`bdd.md`](bdd.md) for the supported Gherkin syntax, the step catalog, the context API, reports, and process lifetime.

### Blocks and closures

A block is a function written at the call site, as the last argument of a call or method call:

```ruby
doubled = xs.map do |x|
  x * 2
end
evens = xs.filter do |x| x % 2 == 0 end
total = xs.reduce(0) do |sum, x| sum + x end
xs.each do |x|
  puts("item #{x}")
end
```

- **Where.** `do |a, b| ... end` (or `do ... end` without parameters) right after the `)` of a call, or after a method name without parentheses: `xs.each do ... end`. A user function always needs its parentheses: `run(1) do ... end`, `start() do ... end`; only a function reached through an import alias may drop them, like a module function (`Util.start do ... end`). The block becomes the last argument, so the called function's last parameter must be a `Fn` (`CHECK-BLOCK-TARGET` otherwise, for user functions and builtins alike). `do || ... end` is rejected; write `do ... end`.
- **Lines.** The body may follow the parameters on the same line (`do |x| x * 2 end`) or start on the next one. Blocks may span lines inside parentheses: `puts(String.join(xs.map do |x| ... end, ","))`.
- **`case`, `while`, `for`.** These headers may end with an optional `do`: `case x do`, `while !done do`, `for x in xs do`. That `do` belongs to the header and is never a block. A call with a block in these headers needs parentheses: `case (xs.map do |x| x end) do`.
- **Parameter types** come from the call: the parameter types of the expected `Fn`, or the builtin's rule (`xs.map` gives `x` the element type). They may be annotated: `do |x: Int| ... end`. With neither, `CHECK-BLOCK-TYPE`. A wrong number of parameters is `CHECK-ARITY`.
- **Result.** `return value` leaves the block, not the enclosing function. Without `return`, the value of the last expression statement is the block's value. The result type comes from the expected `Fn` (user functions, `each`, `any?`, `all?`, `filter`, and `reduce`, whose result is the accumulator type); for `map` and `sort_by` it comes from the body, where every `return` and the last expression must agree (`CHECK-TYPE-MISMATCH`). A non-`Void` block must give a value on every path (`CHECK-MISSING-RETURN`). When the result is `Void`, the last statement gives no value.
- **`try`** inside a block returns the error from the block, so the block's result must be `Result[...]` (`CHECK-TRY-CONTEXT` otherwise); write the success as `ok(...)`. The result must be known from the call (a user function's `Fn[..., Result[T]]`), so `try` is not available in `map` and `sort_by` blocks, whose result is inferred.
- **Capture by value.** A block sees every variable visible where it is written and keeps their values from the moment it is created; later assignments outside do not change it. Assigning to an outer variable inside a block is `CHECK-CAPTURED-ASSIGNMENT`: use `reduce` or a `for` loop. Block parameters and new variables cannot reuse a visible name (`CHECK-SHADOWED-NAME`).
- **Values.** A block has type `Fn[A, ..., R]` and works wherever a function value does: stored, returned, passed to `Task.spawn` through a variable, or made into a BDD step with `BDD.step(pattern) do |ctx, args| ... end`. It shares the caller's step budget and call-depth limit. Blocks have no equality or JSON form; `IO.inspect` prints `<Fn>`.

`List.each` calls `f` on each element in order. `List.any?` and `List.all?` stop at the first element that decides the answer.

### Lightweight tasks

`Task` is reserved. Tasks are cooperative tasks on one VM scheduler, for I/O concurrency without new keywords or CPU parallelism; a task yields when it waits for I/O, a timer or another task, and at the end of each turn. A block can be the task function when it is passed through a `Fn` variable or parameter.

```text
Task.spawn(f: Fn[A, R], arg: A) -> Task[R]
Task.await(task: Task[R]) -> R
Task.sleep(milliseconds: Int) -> Void
Task.pending_count() -> Int
Task.unobserved_crash() -> Result[String]
```

Spawn starts a named function immediately with one argument; use a struct for multiple values. Each task has independent scopes, call depth and return handling. Await returns the cached result and may be repeated. False, nil and Result.error are normal results. Tasks have no constructor, equality, fields, indexing or JSON encoding; inspect shows `<Task>`.

A runtime error in a task other than `main` is a crash: it ends only that task, and the rest of the program goes on. Its diagnostic is printed on stderr when it happens, with ` in a task` after the code (`--json` adds `"task": true`). Its running descendants are cancelled; no program can await one of them, since only the crashed subtree holds them (with `Task.map`, a later `Task.await` on a cancelled task will give `error("task: cancelled")` when `R` is a `Result`, and RUNTIME-TASK-CANCELLED otherwise; `HTTP.close_server` cancels only tasks no program holds). The files, sockets, listeners and processes it owns are closed: a handle belongs to the task that opened it, and one passed directly as the `Task.spawn` argument moves to the new task (a handle inside a struct, list or block does not move). When a task returns normally, the handles it still owns go to its parent task. Other tasks that use a closed handle get its closed error. An `HttpClient` is never closed by a crash. `Task.await` on a crashed task returns `error(text)` when `R` is a `Result`, where `text` is `task crashed: CODE at FILE:LINE:COLUMN: MESSAGE`; otherwise the awaiter halts with RUNTIME-TASK-CRASHED at its own await, with that text as the message, so the crash moves up through awaits. Each await of a crashed task gives the same outcome. These still end the whole run: a runtime error in `main`, RUNTIME-STEP-LIMIT, an internal VM error, and System.exit in any task (the run ends with its code). The first of these outcomes wins.

A crash is observed when an await returns its error or halts with RUNTIME-TASK-CRASHED, or when `Test.run` reports it. When `main` returns and a crash was never observed, the run exits 1 and prints one summary line on stderr: `2 task crashes were not observed; first: task crashed: ...` (`--json`: `{"unobserved_crashes":2,"first":"task crashed: ..."}`). `Task.unobserved_crash()` returns `ok(text)` for the first crash no await has observed, or `error("no unobserved crash")`; calling it does not observe the crash.

Returning from the entrypoint ends the run, and pending tasks never run again: explicitly await work that must finish. At the end of a run, however it ends, the VM flushes and closes open files (waiting for the writes; `--flush-timeout` bounds the wait), closes sockets and listeners, and stops and reaps the child processes it started; stdin, stdout and stderr stay open.

Sleep takes nonnegative milliseconds; zero yields. Negative durations halt with RUNTIME-INVALID-DURATION at the argument. Tasks inherit ports, arguments and contextual builtin services. Shared streams have no cross-task ordering guarantee; coordinate who reads input. All tasks, including nested tasks, share the execution's synchronized --max-steps counter.

Pending count returns how many tasks of this run have not ended, not counting `main`: tasks waiting to run, the task that calls it (unless it is `main`), and tasks waiting on a sleep, an await or I/O. A task that has returned or crashed is not counted, even when nothing awaited it.

BDD step handlers may use tasks but must finish them before returning, normally through Task.await: `std/bdd` checks `Task.pending_count()` after each handler, and pending work fails that step with RUNTIME-BDD-PENDING-TASKS; so does a step program whose `main` leaves tasks running when it calls `BDD.run`. Assertions made by tasks count for the step. A context changed in a task is lost unless the handler takes it back from `Task.await`. After the pending check, `std/bdd` checks `Task.unobserved_crash()`: a task that crashed in the step and was not awaited fails that step with RUNTIME-TASK-CRASHED and the crash text as its message. A runtime error in the handler itself ends the scenario's child VM, which fails only that scenario.

### Unit tests (`Test`)

`Test` and `TestCase` are reserved. `Test` is a builtin module for unit tests in the style of ExUnit; it needs no import. A test file is a program whose `main` calls `Test.run` with a list of `Test.test(name) do ... end` blocks.

```text
Test.test(name: String, body: Fn[Result[Void]]) -> TestCase
Test.run(tests: List[TestCase]) -> Void
Test.eq(actual: T, expected: T) -> Result[Void]
Test.ok?(result: Result[T]) -> Result[Void]
Test.error?(result: Result[T]) -> Result[Void]
Test.assert(condition: Bool, message: String) -> Result[Void]
```

`Test.test` builds a `TestCase`, an opaque value that keeps the name, the block and the span of the `Test.test` call; it has no constructor, fields, equality or JSON encoding, and inspect shows `<TestCase>`. The block returns `Result[Void]`, so `try` works inside it and the last assertion can be its result.

Assertions return `ok()` when they hold and `error(text)` when they do not. `Test.eq` compares by value; both arguments have one type, and that type must be a data type: `Int`, `Float`, `Bool`, `String`, `Nil`, `Range`, `Json`, and lists, maps, Results, structs and enums made of them (`Result[Void]` too). Anything else, such as `Fn`, `Task`, a handle or `TestCase`, is CHECK-TYPE-MISMATCH. Lists compare in order, maps by their keys in any order, structs and enums by type, variant and fields, Results by tag and payload, Floats by IEEE 754, and a `Json` at any depth by its canonical text (sorted keys, as `JSON.encode` writes it). A failed `Test.eq` records the message `values are not equal`; its error text is `expected E; actual A`, where both are the inspect form, with each `Json` as its canonical text. `Test.ok?` gives `expected ok; actual A`, `Test.error?` gives `expected an error; actual A`, and `Test.assert` gives its message.

A failed assertion is also recorded on the test it runs in: the test's own task, or a task spawned inside the test. So `Test.eq(a, b)` as a statement, whose Result is dropped, still fails the test, and the first recorded failure is the one reported. Outside a test, an assertion only returns its Result.

`Test.run` never returns: it ends the run with an exit code. It runs only in `main`'s own task: called in any other task (a test, or a task `main` or a test spawned), it fails with RUNTIME-TEST-RUN at the call. It then checks the names: an empty name, or a name used by an earlier test of the list, fails the run with RUNTIME-TEST-NAME at that `Test.test` call. Run directly, as `agentica file.agc`, it then prints `run this file with agentica test` on stderr and exits 2. The test runner (`agentica test`, roadmap 25b) starts the file with the program arguments `--agentica-test list` or `--agentica-test run`, and `Test.run` answers with records on stdout, each one line made of U+001E, `agentica-bdd ` and a JSON object with sorted keys. In both modes the first line on stdin is a token chosen by the runner (empty when stdin is missing or closed). The VM guarantees two things: every record carries the token as `token`, and every record starts a line (a newline is written first when the program's output through `puts`, `print` or `IO.inspect` stopped mid-line; bytes written to `/dev/stdout` with `File` functions are not tracked). The runner checks both, and takes a line as a record only when it starts with the marker and carries the token, so a line the program prints cannot pass for a record. Stdin belongs to the runner in both modes: for the program, from the start of `main`, it is empty (`IO.gets` gives the end-of-input error, `IO.read` gives `""`, `IO.eof?` is true), and file descriptor 0 is `/dev/null`, so `/dev/stdin` reads nothing too.

- `list` writes `{"column":C,"event":"test","line":L,"name":N,"token":T}` for each test in order, at the `Test.test` call, then `{"event":"ready"}`, and ends the run. No test runs.
- `run` reads one test index (from 0) per line on stdin, after the token. For each, it runs the test in a new task, a child of the task that called `Test.run`, waits for it, and writes `{"event":"pass"}` or a `fail` record: the diagnostic as `--json` writes it (`code`, `file`, `message`, `range`) plus `"event":"fail"` and, for an assertion, `expected` and `actual` as the raw texts. At the end of stdin it ends the run. A line that is not a test index in plain digits (no sign, no leading zero) is a `fail` record with RUNTIME-BDD-INFRA, and exit 1.

In both modes, the run ends as a return from `main` does: exit 0, or exit 1 with the summary line on stderr when a task crash was never observed, such as a crash outside every test.

A test fails, in this order, with: the crash of its task (its own code, message and span; reporting it observes the crash); else its first recorded assertion (RUNTIME-TEST-ASSERTION at the assertion, its message, and `expected` and `actual` for `Test.eq`, only `actual` for `Test.ok?` and `Test.error?`, neither for `Test.assert`); else the `error(m)` the block returned (RUNTIME-TEST-ERROR with `m`, at the test); else tasks spawned in the test that were still running when its task ended (RUNTIME-TEST-PENDING-TASKS, at the test); else the first crash of such a task that no await observed (RUNTIME-TASK-CRASHED at the test, with the crash text as its message). After the record, every crash of the test's tasks counts as observed, and its tasks still running are cancelled before the next test, whatever the outcome. A crash prints its diagnostic on stderr as any task crash does. A runtime error in `main`, RUNTIME-STEP-LIMIT and `System.exit` in a test still end the whole run.

Each test's task gets its own `Random` generator, seeded from the run's seed (`--seed`, or the one drawn from the operating system) and the test's name, so a test sees the same values whether it runs alone or after other tests.

### TCP, TLS and HTTP

Networking uses the existing expression syntax and lightweight tasks.
`TCP`, `TLS`, `HttpWire`, `Socket`, `Listener`, `HttpClient`, `HttpServer`,
`Header`, `HttpRequest`, `HttpResponse`, `HttpClientOptions` and
`HttpServerOptions` are reserved; `HTTP` is not, since it is the import
alias of `std/http` ("HTTP client and server (`std/http`)" in the modules
section). Handles are opaque: no constructor, equality, fields or JSON
encoding; inspect prints their type in angle brackets. Handles belong to
their run and close when it ends.
Network access needs no CLI permission flag.

```text
TCP.connect(host: String, port: Int, timeout_ms: Int) -> Result[Socket]
TCP.listen(host: String, port: Int) -> Result[Listener]
TCP.accept(listener: Listener, timeout_ms: Int) -> Result[Socket]
TCP.send(socket: Socket, text: String, timeout_ms: Int) -> Result[Void]
TCP.send_bytes(socket: Socket, bytes: List[Int], timeout_ms: Int) -> Result[Void]
TCP.recv_bytes(socket: Socket, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
TCP.read_line(socket: Socket, timeout_ms: Int) -> Result[String]
TCP.close(socket: Socket) -> Void
TCP.close_listener(listener: Listener) -> Void
TCP.local_port(listener: Listener) -> Int
TLS.connect(host: String, port: Int, ca_file: String, timeout_ms: Int) -> Result[Socket]
TLS.listen(host: String, port: Int, cert_file: String, key_file: String) -> Result[Listener]
```

Listen on port zero for an assigned port. Listen binds every address the
host resolves to, all on one port (`localhost` takes both `127.0.0.1` and
`::1` clients); addresses the system cannot use, such as IPv6 on a host
without it, are skipped. Ports are 1..65535 for connect and 0..65535 for
listen. A host containing NUL is an error. TLS listeners and sockets use the
same TCP operations. TLS verifies certificates and hostnames with TLS 1.2 or
later; there is no way to turn verification off. An empty CA path uses
system trust (the file in `SSL_CERT_FILE`, else the system CA bundle, and
the directories in `SSL_CERT_DIR`); a nonempty path selects a PEM CA file
that replaces system trust, and a missing or empty file makes the connect
fail. A host that is an IP address is checked against the certificate's IP
addresses. The server takes a PEM certificate chain and private key; a bad
file or a key that does not match fails the listen. A peer that closes
without TLS's closing message ends the stream like EOF, so the protocol on
top must detect a cut message.

Timeouts are positive milliseconds and cover the whole operation, including
lock waits. Read and write directions have independent locks; coordinate
which task reads a stream and the order of writes. Timing out an active I/O
operation closes that socket, and later calls on it fail at once with
`network: socket is closed`. Waiting for a lock alone does not close it.
Failures return Results; explicit close is idempotent.

Send encodes UTF-8 and flushes. Byte values must be 0..255, at most 1 MiB per
send_bytes call. recv_bytes accepts 1..1048576, returns available data up to
that count, and returns ok([]) at EOF. TCP supplies a stream, not messages.
read_line handles fragmented UTF-8, strips LF or CRLF, accepts a final line
without a terminator at EOF, and errors on empty EOF, on a read error (a
connection reset in the middle of a line is an error, not a line) and on a
line over 1 MiB, which also closes the socket.

Builtin records are immutable and use the existing named-field constructors:

| Record | Fields |
| --- | --- |
| Header | name: String, value: String |
| HttpRequest | method: String, target: String, path: String, headers: List[Header], body: String |
| HttpResponse | status: Int, headers: List[Header], body: String |
| HttpClientOptions | timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int, ca_file: String |
| HttpServerOptions | request_timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int |

Header values use the HTTP Latin-1 byte range; names must be HTTP tokens.
CR/LF injection, control characters and user-supplied framing headers are
rejected. The HTTP calls are in "HTTP client and server (`std/http`)".

### Files and paths

`File`, `Dir`, `Path`, `FileHandle` and `FileInfo` are reserved. File handles
are opaque, belong to one evaluation, and close when it ends. The interpreter
uses the host user's filesystem permissions; there is no filesystem permission
flag. File operations accept regular files and symlinks to regular files, and
reject directories and special files.

```text
File.open(path: String, mode: String, timeout_ms: Int) -> Result[FileHandle]
File.read_bytes(handle: FileHandle, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
File.read_line(handle: FileHandle, timeout_ms: Int) -> Result[String]
File.write(handle: FileHandle, text: String, timeout_ms: Int) -> Result[Void]
File.write_bytes(handle: FileHandle, bytes: List[Int], timeout_ms: Int) -> Result[Void]
File.flush(handle: FileHandle, timeout_ms: Int) -> Result[Void]
File.close(handle: FileHandle, timeout_ms: Int) -> Result[Void]
File.read_text(path: String, timeout_ms: Int) -> Result[String]
File.write_text(path: String, text: String, timeout_ms: Int) -> Result[Void]
File.append_text(path: String, text: String, timeout_ms: Int) -> Result[Void]
File.stat(path: String, timeout_ms: Int) -> Result[FileInfo]
Dir.list(path: String, timeout_ms: Int) -> Result[List[String]]
Dir.mkdir(path: String, timeout_ms: Int) -> Result[Void]
Path.cwd() -> Result[String]
Path.join(parts: List[String]) -> Result[String]
Path.resolve(path: String) -> Result[String]
```

`File.open` modes are `read`, `write` and `append`. Read requires an existing
regular file; write creates or truncates; append creates or appends. Text is
strict UTF-8. Whole-text helpers and each stream read/write are limited to
1 MiB; `read_bytes` takes 1..1048576 bytes and returns `ok([])` at EOF.
`read_line` removes LF or CRLF, accepts a final unterminated line, and returns
an error for EOF before any line or invalid UTF-8. Byte values are 0..255.
`File.close` flushes output and is idempotent. Explicit flush and close return
Results so I/O failures remain recoverable.

Timeouts are positive milliseconds and include the serialized handle lock wait.
Timing out active I/O closes that handle; timing out while waiting for its lock
leaves it open. Errors are Results. `File.stat` follows symlinks and reports
`FileInfo(kind: String, size_bytes: Int, modified_seconds: Int)`; directory
sizes are zero. `Dir.list` returns immediate entry names sorted by name.
`Dir.mkdir` creates parents and succeeds when the directory already exists.
`Path.join` follows the host's path rules. `Path.resolve` makes a lexical
absolute path and does not resolve symlinks.

### Builtin discovery and execution budget

`Map.get` and `ok` select signatures by arity. Their text help lists all variants; JSON help contains `name`, `description`, `effects`, and `overloads`, whose entries describe each signature. Other builtin help keeps the single-signature JSON format.

`agentica help NAME --json` prints name, arity, parameter types, result, signature, effects, and description from the same catalog used by checking and execution. Effects say what a builtin does besides returning its result: I/O, tasks, or `test` for an assertion that records a failure on its test. They are informational, not permission enforcement; a call to a builtin with no effects whose result is unused is CHECK-UNUSED-VALUE. Unknown help targets exit 2. Options may also precede `help`.

`agentica --max-steps N program.agc` limits execution to N expression/statement entries, including repeated loop conditions across all tasks. N must be a positive integer (bad CLI values exit 2). Runs are unlimited by default; checking never executes or spends the budget. Exhaustion is `RUNTIME-STEP-LIMIT` at the next node to execute. The synchronized counter resets per evaluation. This is not a wall-clock or blocking-I/O timeout.

At the end of a run the VM writes the buffered output of every file still open and waits until those writes finish. `agentica --flush-timeout MS program.agc` waits at most MS milliseconds (a non-negative integer; bad values exit 2). When time runs out the run still ends, with the same exit code, and stderr gets one line saying that file data may not be written: `agentica: file data may not be written: the flush took longer than MS ms`, or in `--json` mode `{"flush_timeout_ms": MS, "warning": "file data may not be written"}`. Without the flag there is no limit, so a write to a FIFO nobody reads keeps the run open.

Calls nest at most 10000 deep in each task; a deeper call is `RUNTIME-STACK-OVERFLOW` at the call. A tail call (`return f(...)`, a direct call to a user function) replaces the caller's frame and does not count toward this limit, so deep tail recursion runs.


### Processes

Process is an opaque handle with no constructor, fields, equality, or JSON encoding. IO.inspect prints `<Process>`.

~~~text
Process.spawn(command: String, args: List[String], timeout_ms: Int) -> Result[Process]
Process.send(p: Process, text: String, timeout_ms: Int) -> Result[Void]
Process.send_bytes(p: Process, bytes: List[Int], timeout_ms: Int) -> Result[Void]
Process.read_line(p: Process, timeout_ms: Int) -> Result[String]
Process.read_bytes(p: Process, count: Int, timeout_ms: Int) -> Result[List[Int]]
Process.close_stdin(p: Process, timeout_ms: Int) -> Result[Void]
Process.wait(p: Process, timeout_ms: Int) -> Result[Int]
Process.close(p: Process) -> Void
Process.spawn_captured(command: String, args: List[String], dir: String, timeout_ms: Int) -> Result[Process]
Process.output(p: Process, timeout_ms: Int) -> Result[ProcessOutput]
~~~

- Launching requires agentica --allow-run file.agc. The flag defaults off and precedes the source file; later arguments reach System.args. The test command accepts it before or after the command. Checking and builtin help need no flag. Permission reaches tasks. BDD step handlers can always launch programs, because `agentica test` runs every scenario's child VM with `--allow-run`; `agentica test --allow-run` only passes the flag on to the programs under test.
- A command with no `/` is a bare name: it is looked up in each `PATH` entry in order. The working directory is never added: empty `PATH` entries are skipped, so a program in the current directory runs as `./name`, while an explicit relative entry such as `.` or `bin` resolves against the working directory, as in the shell. A command that contains `/` is a path, relative to the inherited working directory unless it is absolute. A name that is not found, or that names a directory, is "executable is unavailable". Children inherit the environment. Arguments are passed directly without shell interpolation. Empty commands, NUL-containing arguments, and unavailable executables fail. On Windows only `.exe` and `.com` programs run; other files, such as batch files, fail. A file that is found but cannot be executed (no execute permission, a bad format) is an error Result from `spawn`.
- Timeouts are positive milliseconds, including lock wait. Read and write locks are independent. A timeout after starting stream I/O kills and closes the child; timing out while waiting for its lock preserves it. Waiting for exit times out without terminating the child.
- Sends accept at most 1048576 UTF-8 bytes or integers 0..255 and flush before succeeding. Invalid data consumes nothing. read_bytes accepts 0..1048576 and waits for that count or EOF: short/empty EOF succeeds, and zero consumes nothing.
- read_line consumes a line of at most 1 MiB, strips LF/CRLF, and strictly decodes UTF-8. An unterminated final line succeeds; empty EOF is an error. Invalid UTF-8 consumes the completed line. An oversized line closes the child.
- close_stdin flushes and closes input idempotently; further sends fail. wait returns the host exit code, including nonzero codes, and can be repeated. It preserves unread stdout and waits for stderr forwarding to finish.
- Stderr streams separately to the program's stderr with a fixed-size buffer. Output has no lifetime cap. A child can block when stdout's pipe fills: use Task to read concurrently with sending or waiting.
- Handles belong to their evaluation. close force-kills a running child, reaps it, closes owned ports/workers, and is idempotent. Other operations on closed handles fail. Main return, System.exit, diagnostics, task failures, step exhaustion, and external interruption also clean up directly spawned children. Arbitrary descendant trees are outside the cleanup guarantee. Borrowed ports remain open.
- Operational failures return String error Results. Explicit cleanup failures are RUNTIME-PROCESS-CLOSE, at the call span.
- Captured processes. `spawn_captured` works like `spawn` (same lookup, `--allow-run`, environment and cleanup) with three differences. The child starts in `dir`: `"."` keeps the working directory, a relative `dir` resolves against it, an empty `dir` or one with NUL is an error, and a `dir` that is not a directory is "directory is unavailable". The command still resolves against the program's working directory, not `dir`, so `spawn_captured("./sh", [], "/bin", t)` is "executable is unavailable". The VM reads the child's stdout and stderr all the time, so the child never blocks on a full pipe: stdout goes into a buffer that `read_line` and `read_bytes` read, stderr into its own buffer and never to the program's stderr. Past 1 MiB of unread stdout, or 1 MiB of stderr, that stream is marked truncated and further bytes are dropped. Once either stream is truncated, every stdout read returns `error("process: output exceeds 1048576 bytes")`: a read already waiting wakes with it, and `read_bytes(p, 0, t)` returns it at once, so a program can check for a stderr flood without waiting.
- `output` waits until the child's stdout and stderr both end, then returns the builtin record `ProcessOutput(stdout: String, stderr: String, truncated: Bool)`: the stdout not read yet, all of stderr (invalid UTF-8 becomes U+FFFD), and whether either stream was truncated. It consumes nothing and can be called again. A timeout is `error("network: operation timed out")` and keeps the child; a process from `spawn` gives `error("process: output is not captured")`. `ProcessOutput` is reserved.
- Closing a captured child (`close`, a stream timeout, the end of the run) sends `SIGTERM`, then `SIGKILL` after one second, so a child that is itself an Agentica program can stop its own children first. `close` and a timeout close the handle at once and never wait; the end of the run waits about one second at most for a captured child before it kills it. Children from `spawn` are still killed at once.

## 7. Diagnostics for agents

Each error includes a stable code, file, line, column, a concrete explanation, and the source line with a mark under the span. Spans travel from the tokens to the AST.

```text
example.agc:2:14 error[CHECK-TYPE-MISMATCH]
expected Int, found String

2 |   age: Int = "25"
  |              ^^^^
```

When the checker knows a certain fix, the diagnostic ends with a `= help:` line, and secondary spans are marked with `-` and a short note:

```text
example.agc:5:7 error[CHECK-UNKNOWN-NAME]
unknown function "totl"

5 |   x = totl(1)
  |       ^^^^^^^
  = help: did you mean "total"?
```

`agentica --ai` and `agentica --json` print the same diagnostic as compact text or as one JSON object. In `--json` mode, when a diagnostic ends the run, the last line of stderr is that diagnostic; what the program itself wrote to stderr comes before it. Task crash lines carry `"task": true` and are not the run's diagnostic: a run can exit 0 with only crash lines, and a run that exits 1 because a crash was never observed ends with the `{"unobserved_crashes": N, "first": "..."}` line instead of a diagnostic. The `{"flush_timeout_ms": ...}` warning of `--flush-timeout` is not a diagnostic either; it comes after the unobserved line and before a diagnostic.

The code carries the prefix of the stage that failed: `LEX-`, `PARSE-`, `CHECK-` (before running), or `RUNTIME-` (while running); the VM compiler stages use `LOWER-` and `BYTECODE-`. Each stage stops at the first error. The minimal cases to tell apart are: invalid syntax, unknown name, incompatible type, wrong arity, unknown or missing field, missing return, and runtime error.

Names and forms from other languages get a `help` that names the Agentica form. A method hint is given only when the suggested method exists for the receiver's type:

| Written | Help |
|---|---|
| `len(x)`, `x.len` | `x.size` for lists and maps, `s.length` for strings |
| `str(x)`, `x.to_string()` | `x.to_s` or `"#{x}"` |
| `inspect(x)` | `x.inspect`, or `IO.inspect(x)` to print it |
| `println(x)` | `puts(x)` |
| `input()`, `read_line()` | `gets` (a Result) or `gets!` |
| `range(n)` | a range: `for i in 0...n`, or `n.times do \|i\| ... end` |
| `int(x)`, `float(n)`, `Int.to_float(n)` | `x.to_i`, `n.to_f` |
| `x.lower`, `x.upper`, `x.startswith(...)` | `downcase`, `upcase`, `start_with?` |
| `x.nil?` | `x == nil` |
| `None`, `null` | `nil` |
| `elif`, `elseif`, `else if` | `elsif` |
| `let x = 5`, `var x = 5`, `const x = 5` | `x = 5` or `x: Int = 5` |
| `match x`, `when 1` in a `case` | `case x`, arms as `1 -> ...` |
| `if x then` | a newline after the condition |
| `fn(x: Int) ...`, `lambda do ... end`, a `do` block with no call | a block after a call (`xs.map do \|x\| ... end`) or `&name` |
| `Hash.new`, `Array.new` | a typed literal: `m: Map[String, Int] = {}`, `xs: List[Int] = []` |
| `continue` | `next` |
| `break if x`, `next if x` | `if x`, then `break` on its own line, then `end` |
| `loop do ... end` | `while true ... end`, or a `while` condition |
| `puts(x) if ok`, `if x do` | `if ok ... end`; an `if` condition ends with a newline |
| `Result.Some(x)` and other unknown Result variants | `Result.Ok(x)` / `ok(x)`, `Result.Err(m)` / `error(m)` |
| `Color.Red` with no `Color` enum or import | `enum Color`, or `import "path" as Color` |
| a `Result[T]` where `T` is expected (`n: Int = s.to_i`) | a `!` form (`s.to_i!`), `Result.unwrap!`, or `try` |
| `HttpWire.exchange(...)` or another `HttpWire` call outside `std/http` | `import "std/http" as HTTP`, then `HTTP.get`, `HTTP.post` or `HTTP.request` |
| `HTTP.get(...)` or another `HTTP.` call without the import | `import "std/http" as HTTP` |
| `HTTP.respond(writer, ...)`, `HTTP.begin`, `HTTP.write`, `HTTP.write_bytes`, `HTTP.finish` with the import (`CHECK-IMPORT-NAME`) | a handler that returns its whole response: `return ok(HttpResponse(status: 200, headers: [], body: text))` |
| `Request` or `HttpWriter` as a type, in a parameter, return type or variable (`CHECK-UNKNOWN-TYPE`) | `def handle(request: HttpRequest) -> Result[HttpResponse]` |

Diagnostics refer to Agentica and never expose host exceptions or tracebacks.

## 8. Examples to review the design

### Function and control flow

```ruby
def classify(age: Int) -> String
  if age >= 18
    return "adult"
  elsif age >= 13
    return "teen"
  else
    return "child"
  end
end

def main() -> Void
  puts(classify(25))
end
```

### Lists and field access

```ruby
struct Todo
  title: String
  done: Bool
end

def main() -> Void
  tasks: List[Todo] = [
    Todo(title: "Probar Agentica", done: false),
    Todo(title: "Revisar gramática", done: true)
  ]

  for task in tasks
    if !task.done
      puts(task.title)
    end
  end
end
```

### Maps

```ruby
def main() -> Void
  stock: Map[String, Int] = {"apple": 3, "pear": 0}
  stock = stock.put("kiwi", 7)
  for name in stock.keys
    if stock[name] > 0
      puts(name)
    end
  end
end
```

### Programs that must be rejected

```ruby
age: Int = "25"        # Incompatible types.
if 1                   # The condition must be Bool.
  puts("hello")
end
values = []            # Missing expected type for the empty list.
puts "hello"           # The call requires parentheses.
```

These statements are shown as function body fragments. At the top level they would also be invalid because they are not declarations.

## 9. Guide for whoever implements the prototype

Implement the rules of sections 4–6 first. Keep the grammar, the AST, the checker, the VM, and the builtin functions independent. Do not generate host code without preserving the rules of Agentica: for example, `if 1` must be rejected even if the host accepts truthiness.

If a rule turns out to be too costly, change this specification and the examples explicitly before creating a silent exception. The goal is that any agent can consult a short document and predict the behavior of a program.

The first evaluation of the language should measure correct programs, attempts needed, and how useful the errors are. Run time can be measured later; the first question is whether the syntax and the rules help agents produce and repair code.
