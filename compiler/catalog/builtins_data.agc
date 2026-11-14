## The builtin records, enums and reserved type names as module constants (the rows are in builtins_<module>.agc).
## Edited by hand; they were generated from the former front end. The catalog test compares what it prints with a
## golden.

import Types from "../syntax/types"
import Model from "builtin_model"

## The builtin record types, sorted by name.
RECORDS: List[Model.Record] = [
  # The payload of a failed Result. vm/builtins.c (agc_error_struct) takes it as the builtin Error only with these
  # fields, in this order and of these types: keep them in step. cause names the record itself.
  Model.Record(
    name: "Error",
    fields: [
      Model.Named(name: "kind", type: Types.Type.String, default: Model.Default.Text("error")),
      Model.Named(name: "message", type: Types.Type.String),
      Model.Named(name: "code", type: Types.Type.Optional(Types.Type.Int), default: Model.Default.None),
      Model.Named(
        name: "details",
        type: Types.Type.Map(Types.Type.String, Types.Type.String),
        default: Model.Default.EmptyMap,
      ),
      Model.Named(
        name: "cause",
        type: Types.Type.Optional(Types.Type.Struct("Error", [])),
        default: Model.Default.None,
      ),
      Model.Named(name: "location", type: Types.Type.String, default: Model.Default.Text("")),
    ],
  ),
  Model.Record(
    name: "File.Info",
    fields: [
      Model.Named(name: "kind", type: Types.Type.String),
      Model.Named(name: "size_bytes", type: Types.Type.Int),
      Model.Named(name: "modified_seconds", type: Types.Type.Int),
      Model.Named(name: "mode", type: Types.Type.Int),
      Model.Named(name: "user_id", type: Types.Type.Int),
      Model.Named(name: "group_id", type: Types.Type.Int),
    ],
  ),
  # The records of HttpWire, which std/http re-exports (HTTP.Header, HTTP.Request, ...). vm/http_fields.c makes
  # HttpWire.Header and vm/http_wire.c HttpWire.Head, HttpWire.ResponseHead, HttpWire.Chunk and HttpWire.Reply by name.
  Model.Record(
    name: "HttpWire.Header",
    fields: [Model.Named(name: "name", type: Types.Type.String), Model.Named(name: "value", type: Types.Type.String)],
  ),
  # vm/value.h names these field positions (AGC_HTTP_OPTIONS_FIELDS, AGC_HTTP_OPTION_PROXY and AGC_HTTP_OPTION_TLS):
  # keep them in step.
  Model.Record(
    name: "HttpWire.ClientOptions",
    fields: [
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
      Model.Named(name: "idle_timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
      Model.Named(name: "max_connections", type: Types.Type.Int, default: Model.Default.Whole(4)),
      Model.Named(name: "max_body_bytes", type: Types.Type.Int, default: Model.Default.Whole(1048576)),
      Model.Named(name: "proxy", type: Types.Type.String, default: Model.Default.Text("")),
      Model.Named(
        name: "tls",
        type: Types.Type.Optional(Types.Type.Opaque("TLS.Context")),
        default: Model.Default.None,
      ),
    ],
  ),
  Model.Record(
    name: "HttpWire.Request",
    fields: [
      Model.Named(name: "method", type: Types.Type.String),
      Model.Named(name: "target", type: Types.Type.String),
      Model.Named(name: "path", type: Types.Type.String),
      Model.Named(name: "headers", type: Types.Type.List(Types.Type.Struct("HttpWire.Header", []))),
      Model.Named(name: "body", type: Types.Type.Bytes),
      Model.Named(name: "remote_addr", type: Types.Type.String, default: Model.Default.Text("")),
    ],
  ),
  Model.Record(
    name: "HttpWire.Response",
    fields: [
      Model.Named(name: "status", type: Types.Type.Int),
      Model.Named(name: "headers", type: Types.Type.List(Types.Type.Struct("HttpWire.Header", []))),
      Model.Named(name: "body", type: Types.Type.Bytes),
    ],
  ),
  Model.Record(
    name: "HttpWire.ServerOptions",
    fields: [
      Model.Named(name: "request_timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
      Model.Named(name: "idle_timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
      Model.Named(name: "max_connections", type: Types.Type.Int, default: Model.Default.Whole(128)),
      Model.Named(name: "max_body_bytes", type: Types.Type.Int, default: Model.Default.Whole(1048576)),
    ],
  ),
  Model.Record(
    name: "HttpWire.Chunk",
    fields: [
      Model.Named(name: "done", type: Types.Type.Bool),
      Model.Named(name: "next", type: Types.Type.Int),
      Model.Named(name: "runs", type: Types.Type.List(Types.Type.Int)),
      Model.Named(name: "state", type: Types.Type.Int),
      Model.Named(name: "remaining", type: Types.Type.Int),
      Model.Named(name: "size", type: Types.Type.Int),
      Model.Named(name: "line", type: Types.Type.Int),
      Model.Named(name: "block", type: Types.Type.Int),
      Model.Named(name: "count", type: Types.Type.Int),
      Model.Named(name: "name", type: Types.Type.String),
      Model.Named(name: "name_length", type: Types.Type.Int),
      Model.Named(name: "total", type: Types.Type.Int),
      Model.Named(name: "limit", type: Types.Type.Int),
    ],
  ),
  Model.Record(
    name: "HttpWire.Head",
    fields: [
      Model.Named(name: "method", type: Types.Type.String),
      Model.Named(name: "target", type: Types.Type.String),
      Model.Named(name: "path", type: Types.Type.String),
      Model.Named(name: "headers", type: Types.Type.List(Types.Type.Struct("HttpWire.Header", []))),
      Model.Named(name: "length", type: Types.Type.Int),
      Model.Named(name: "chunked", type: Types.Type.Bool),
      Model.Named(name: "expect_continue", type: Types.Type.Bool),
      Model.Named(name: "buffered", type: Types.Type.Int),
      Model.Named(name: "status", type: Types.Type.Int),
      Model.Named(name: "reason", type: Types.Type.String),
    ],
  ),
  Model.Record(
    name: "HttpWire.Job",
    fields: [
      Model.Named(name: "origin", type: Types.Type.String),
      Model.Named(name: "scheme", type: Types.Type.String),
      Model.Named(name: "host", type: Types.Type.String),
      Model.Named(name: "port", type: Types.Type.Int),
      Model.Named(name: "method", type: Types.Type.String),
      Model.Named(name: "head", type: Types.Type.String),
      Model.Named(name: "body", type: Types.Type.Bytes),
      Model.Named(name: "deadline", type: Types.Type.Int),
      Model.Named(
        name: "reply",
        type: Types.Type.Channel(Types.Type.Result(Types.Type.Struct("HttpWire.Response", []))),
      ),
      Model.Named(name: "worker", type: Types.Type.Int),
      Model.Named(name: "kept", type: Types.Type.Bool),
    ],
  ),
  Model.Record(
    name: "HttpWire.Reply",
    fields: [Model.Named(name: "head", type: Types.Type.String), Model.Named(name: "closes", type: Types.Type.Bool)],
  ),
  Model.Record(
    name: "HttpWire.ResponseHead",
    fields: [
      Model.Named(name: "status", type: Types.Type.Int),
      Model.Named(name: "headers", type: Types.Type.List(Types.Type.Struct("HttpWire.Header", []))),
      Model.Named(name: "length", type: Types.Type.Int),
      Model.Named(name: "chunked", type: Types.Type.Bool),
      Model.Named(name: "until_close", type: Types.Type.Bool),
      Model.Named(name: "closes", type: Types.Type.Bool),
      Model.Named(name: "buffered", type: Types.Type.Int),
      Model.Named(name: "ended", type: Types.Type.Bool),
    ],
  ),
  Model.Record(
    name: "LogRegistry.Event",
    fields: [
      Model.Named(name: "level", type: Types.Type.Enum("LogRegistry.Level", [])),
      Model.Named(name: "message", type: Types.Type.String),
      Model.Named(name: "fields", type: Types.Type.Map(Types.Type.String, Types.Type.String)),
      Model.Named(name: "time_ms", type: Types.Type.Int),
      Model.Named(name: "task", type: Types.Type.Int),
    ],
  ),
  # The options of Process.spawn, spawn_captured and spawn_channel. vm/process.c reads the fields by position
  # (OPTION_* there; tests/test_process.py test_options_layout checks the two orders agree).
  Model.Record(
    name: "Process.Options",
    fields: [
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
      Model.Named(name: "chdir", type: Types.Type.String, default: Model.Default.Text(".")),
      Model.Named(
        name: "env",
        type: Types.Type.Map(Types.Type.String, Types.Type.String),
        default: Model.Default.EmptyMap,
      ),
      Model.Named(name: "out", type: Types.Type.String, default: Model.Default.Text("")),
      Model.Named(name: "err", type: Types.Type.String, default: Model.Default.Text("")),
      Model.Named(name: "pgroup", type: Types.Type.Bool, default: Model.Default.Flag(false)),
    ],
  ),
  Model.Record(
    name: "Process.Output",
    fields: [
      Model.Named(name: "stdout", type: Types.Type.String),
      Model.Named(name: "stderr", type: Types.Type.String),
      Model.Named(name: "truncated", type: Types.Type.Bool),
    ],
  ),
  # Lowering builds it for T.codec (Data.lower_codec): the linked name of the type, then the fields of T.members.
  Model.Record(
    name: "Codec.Info",
    fields: [
      Model.Named(name: "name", type: Types.Type.String),
      Model.Named(name: "members", type: Types.Type.List(Types.Type.Struct("StructMember", []))),
    ],
  ),
  Model.Record(
    name: "StructMember",
    fields: [Model.Named(name: "name", type: Types.Type.String), Model.Named(name: "type", type: Types.Type.String)],
  ),
  # vm/task.c builds it with these fields in this order (monitor_down): keep them in step.
  Model.Record(
    name: "TaskDown",
    fields: [
      Model.Named(name: "task_id", type: Types.Type.Int),
      Model.Named(name: "reason", type: Types.Type.Enum("TaskExit", [])),
      Model.Named(name: "code", type: Types.Type.String),
      Model.Named(name: "message", type: Types.Type.String),
      Model.Named(name: "file", type: Types.Type.String),
      Model.Named(name: "line", type: Types.Type.Int),
      Model.Named(name: "column", type: Types.Type.Int),
    ],
  ),
  # vm/tls_context.c reads these fields by position: keep them in step.
  Model.Record(
    name: "TLS.ClientOptions",
    fields: [
      Model.Named(name: "ca_file", type: Types.Type.String, default: Model.Default.Text("")),
      Model.Named(name: "cert_file", type: Types.Type.String, default: Model.Default.Text("")),
      Model.Named(name: "key_file", type: Types.Type.String, default: Model.Default.Text("")),
      Model.Named(name: "alpn", type: Types.Type.List(Types.Type.String), default: Model.Default.EmptyList),
    ],
  ),
  Model.Record(
    name: "TLS.ServerOptions",
    fields: [
      Model.Named(name: "cert_file", type: Types.Type.String),
      Model.Named(name: "key_file", type: Types.Type.String),
      Model.Named(name: "alpn", type: Types.Type.List(Types.Type.String), default: Model.Default.EmptyList),
    ],
  ),
]

## The builtin enums, whose variants are written without an import.
ENUMS: List[Model.EnumDef] = [
  Model.EnumDef(
    name: "Await",
    parameters: ["T"],
    variants: [
      Model.Variant(name: "Done", payload: [Types.Type.Var("T")]),
      Model.Variant(name: "TimedOut", payload: []),
    ],
  ),
  Model.EnumDef(
    name: "JSON.Field",
    parameters: ["T"],
    variants: [
      Model.Variant(name: "Absent", payload: []),
      Model.Variant(name: "Null", payload: []),
      Model.Variant(name: "Value", payload: [Types.Type.Var("T")]),
    ],
  ),
  Model.EnumDef(
    name: "JSON.Node",
    parameters: [],
    variants: [
      Model.Variant(name: "Null", payload: []),
      Model.Variant(name: "Bool", payload: [Types.Type.Bool]),
      Model.Variant(name: "Int", payload: [Types.Type.Int]),
      Model.Variant(name: "BigInt", payload: [Types.Type.String]),
      Model.Variant(name: "Float", payload: [Types.Type.Float]),
      Model.Variant(name: "String", payload: [Types.Type.String]),
      Model.Variant(name: "Array", payload: [Types.Type.List(Types.Type.Json)]),
      Model.Variant(name: "Object", payload: [Types.Type.Map(Types.Type.String, Types.Type.Json)]),
    ],
  ),
  Model.EnumDef(
    name: "LogRegistry.Level",
    parameters: [],
    variants: [
      Model.Variant(name: "Debug", payload: []),
      Model.Variant(name: "Info", payload: []),
      Model.Variant(name: "Warning", payload: []),
      Model.Variant(name: "Error", payload: []),
    ],
  ),
  Model.EnumDef(
    name: "System.Signal",
    parameters: [],
    variants: [
      Model.Variant(name: "Term", payload: []),
      Model.Variant(name: "Int", payload: []),
      Model.Variant(name: "Hup", payload: []),
      Model.Variant(name: "Usr1", payload: []),
      Model.Variant(name: "Usr2", payload: []),
      Model.Variant(name: "Quit", payload: []),
      Model.Variant(name: "Kill", payload: []),
    ],
  ),
  Model.EnumDef(
    name: "TaskExit",
    parameters: [],
    variants: [
      Model.Variant(name: "Ok", payload: []),
      Model.Variant(name: "Crashed", payload: []),
      Model.Variant(name: "Cancelled", payload: []),
    ],
  ),
]

## The handle types a task can be given with Task.spawn_owning.
HANDLE_TYPES: List[String] = ["TCP.Socket", "TCP.Listener", "HttpWire.Server", "File.Handle", "Process"]

## The builtin types with no structure: handles, Test.Case, TLS.Context, C.Pointer (a C pointer of native code),
## TaskRef (the running task, from Task.current) and Native.Mutex (the lock of a native library).
OPAQUE_TYPES: List[String] = [
  "TCP.Socket", "TCP.Listener", "HttpWire.Client", "HttpWire.Server", "File.Handle", "Process", "Test.Case",
  "TLS.Context", "C.Pointer", "TaskRef", "Native.Mutex",
]

TYPE_DESCRIPTIONS: Map[String, String] = {
  "Await": "What Task.await with a timeout returns: Done with the task's value, or TimedOut.",
  "C.Pointer": "A C pointer of native code, from an extern call or Native.memory_pointer.",
  "Codec.Info": "What T.codec returns for a struct T: its name and its members, in declaration order.",
  "Error": "The payload of a failed Result: its kind, message, code, details, cause and the place it was made.",
  "File.Handle": "An open file, from File.open; File.close closes it.",
  "File.Info": "What File.stat returns: the kind, byte size, modification time, permission bits and owner of a file.",
  "JSON.Field": "A field of a JSON struct that may be missing or null: Absent, Null or Value(T).",
  "JSON.Node": "One level of a JSON.Value, from JSON.node, to match with case.",
  "JSON.Value": "A JSON document of any shape, from JSON.parse; the JSON functions read it.",
  "Native.Mutex": "The lock of a native library, from Native.mutex; synchronize runs a block holding it.",
  "Process": "A program started by Process.spawn, spawn_captured, spawn_channel or spawn_group.",
  "Process.Options": "The options of Process.spawn, spawn_captured and spawn_channel; give only the fields you need.",
  "Process.Output": "What Process.output returns: the unread stdout, all stderr and whether output was dropped.",
  "StructMember": "A member of a struct as T.codec lists it: its name and its type as written.",
  "System.Signal": "A signal of the operating system, which System.subscribe delivers on a channel.",
  "TCP.Listener": "A listening TCP socket, from TCP.listen or TLS.listen; TCP.accept takes its connections.",
  "TCP.Socket": "A connected TCP socket, from TCP.connect, TCP.accept or TLS.connect.",
  "TLS.ClientOptions": "The options of TLS.client_context: the CA file, a client certificate and key, and ALPN.",
  "TLS.Context": "The certificates and settings of TLS connections, from TLS.client_context or TLS.server_context.",
  "TLS.ServerOptions": "The options of TLS.server_context: the certificate and key files, and ALPN.",
  "TaskDown": "The notice that Task.monitor sends when a watched task ends: how it ended and, for a crash, where.",
  "TaskExit": "How a task ended: Ok, Crashed or Cancelled.",
  "TaskRef": "The running task, from Task.current, which Task.monitor, Task.cancel and id take.",
  "Test.Case": "A test case, from Test.test; Test.run runs a list of them.",
}

## The type names no declaration or import alias may take.
RESERVED_TYPE_NAMES: List[String] = [
  "ATS",
  "Await",
  "Base64",
  "Bool",
  "Bytes",
  "Channel",
  "Codec",
  "Dir",
  "Error",
  "File",
  "Float",
  "Fn",
  "IO",
  "Int",
  "JSON",
  "Lazy",
  "List",
  "Map",
  "Math",
  "Nil",
  "OpenSSL",
  "Optional",
  "Path",
  "Process",
  "Random",
  "Range",
  "Result",
  "Set",
  "String",
  "StructMember",
  "System",
  "TCP",
  "TLS",
  "Task",
  "TaskDown",
  "TaskExit",
  "TaskRef",
  "Test",
  "Time",
  "Void",
  "Zlib",
]

## The builtin families. Each reserves its one name (in RESERVED_TYPE_NAMES), and its members are written
## Family.Member: a group of functions (the rows named Family.Member.fn) or a builtin type named Family.Member (a
## record, an enum or an opaque type). A new member, or a new function of a member, only adds its rows or its type and
## reserves no name.
FAMILIES: List[String] = ["File", "JSON", "OpenSSL", "Process", "System", "TCP", "TLS", "Test"]

## The kinds of the errors that the builtins and std/ build (issue #671): the C kinds of kind_names in vm/value.c, in
## its order, then the kinds of the std/ modules. A kind is a contract, only added and never renamed. A first segment
## here is a builtin family, which LINT-ERROR-KIND holds an is_a? literal to. tests/test_error_kinds.py checks that the
## list is the C kinds and the std/ kinds, no more and no fewer.
ERROR_KINDS: List[String] = [
  "error",
  "argument",
  "io.not_found",
  "io.permission",
  "io.exists",
  "io.is_directory",
  "io.not_directory",
  "io.too_large",
  "io.eof",
  "io.closed",
  "io.timeout",
  "io.failed",
  "net.timeout",
  "net.refused",
  "net.host_not_found",
  "net.closed",
  "net.eof",
  "net.tls",
  "net.too_large",
  "net.failed",
  "http.protocol",
  "http.too_large",
  "http.closed",
  "process.not_found",
  "process.timeout",
  "process.closed",
  "process.eof",
  "process.too_large",
  "process.failed",
  "task.crashed",
  "task.cancelled",
  "task.timeout",
  "channel.closed",
  "channel.timeout",
  "channel.gone",
  "json.parse",
  "json.decode",
  "number.parse",
  "number.range",
  "text.encoding",
  "zlib.data",
  "zlib.too_large",
  "crypto.auth",
  "crypto.key",
  "crypto.failed",
  "system.env",
  "native.failed",
  "native.timeout",
  "test.failed",
  "denied.env",
  "denied.fs",
  "denied.net",
  "denied.run",
  "system.signal",
  "archive.format",
  "archive.not_found",
  "archive.timeout",
  "archive.too_large",
  "archive.unsafe",
  "binary.too_large",
  "option_parser.help",
  "option_parser.parse",
  "regex.syntax",
  "toml.decode",
  "toml.parse",
]

## The modules only std/ may call: each name with the std module that wraps it and the alias its help shows.
STD_ONLY_IMPORTS: Map[String, List[String]] = {
  "HttpWire": ["std/http", "HTTP"],
  "LogRegistry": ["std/logger", "Logger"],
  "RegexEngine": ["std/regex", "Regex"],
}
