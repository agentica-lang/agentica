## The builtin catalog and reserved type names as module constants. Edited by
## hand; they were generated from the former front end. The catalog test compares
## what it prints with a golden.

import Model from "builtin_model"
import Types from "../check/types"

## Every builtin, sorted by name.
BUILTIN_GROUP_1 = ROWS_1.concat(ROWS_2.concat(ROWS_3.concat(ROWS_4.concat(ROWS_5))))
BUILTIN_GROUP_2 = ROWS_6.concat(ROWS_7.concat(ROWS_8.concat(ROWS_9.concat(ROWS_10))))
BUILTIN_GROUP_3 = ROWS_11.concat(ROWS_12.concat(ROWS_13.concat(ROWS_14.concat(ROWS_15))))
BUILTIN_GROUP_4 = ROWS_16.concat(ROWS_17.concat(ROWS_18.concat(ROWS_19.concat(ROWS_20))))
BUILTIN_GROUP_5 = ROWS_21.concat(ROWS_22.concat(ROWS_23.concat(ROWS_24.concat(ROWS_25))))
BUILTIN_GROUP_6 = ROWS_26.concat(ROWS_27.concat(ROWS_28.concat(ROWS_29.concat(ROWS_30))))
BUILTIN_GROUP_7 = ROWS_31.concat(ROWS_32.concat(ROWS_33.concat(ROWS_34.concat(ROWS_35))))
BUILTIN_GROUP_8 = ROWS_36.concat(ROWS_37.concat(ROWS_38.concat(ROWS_39.concat(ROWS_40))))
BUILTIN_GROUP_9 = ROWS_41.concat(ROWS_42.concat(ROWS_43.concat(ROWS_44.concat(ROWS_45))))
BUILTIN_GROUP_10 = ROWS_46.concat(ROWS_47.concat(ROWS_48.concat(ROWS_49.concat(ROWS_50))))
BUILTIN_GROUP_11 = ROWS_51.concat(ROWS_52.concat(ROWS_53.concat(ROWS_54.concat(ROWS_55))))
BUILTIN_GROUPS_1 = BUILTIN_GROUP_1.concat(BUILTIN_GROUP_2.concat(BUILTIN_GROUP_3))
BUILTIN_GROUPS_2 = BUILTIN_GROUP_4.concat(BUILTIN_GROUP_5.concat(BUILTIN_GROUP_6))
BUILTIN_GROUPS_3 = BUILTIN_GROUP_7.concat(BUILTIN_GROUP_8.concat(BUILTIN_GROUP_9))
BUILTIN_GROUPS_4 = BUILTIN_GROUP_10.concat(BUILTIN_GROUP_11)
export BUILTIN_ROWS: List[Model.Builtin] = BUILTIN_GROUPS_1.concat(BUILTIN_GROUPS_2).concat(
  BUILTIN_GROUPS_3.concat(BUILTIN_GROUPS_4),
)

## The builtin record types, sorted by name.
export RECORDS: List[Model.Record] = [
    Model.Record(
      name: "FileInfo",
      fields: [
        Model.Named(name: "kind", type: Types.Type.String),
        Model.Named(name: "size_bytes", type: Types.Type.Int),
        Model.Named(name: "modified_seconds", type: Types.Type.Int),
        Model.Named(name: "mode", type: Types.Type.Int),
        Model.Named(name: "user_id", type: Types.Type.Int),
        Model.Named(name: "group_id", type: Types.Type.Int),
      ],
    ),
    Model.Record(
      name: "Header",
      fields: [
        Model.Named(name: "name", type: Types.Type.String),
        Model.Named(name: "value", type: Types.Type.String),
      ],
    ),
    # vm/value.h names these field positions (AGC_HTTP_OPTIONS_FIELDS, AGC_HTTP_OPTION_CA_FILE): keep them in step.
    Model.Record(
      name: "HttpClientOptions",
      fields: [
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
        Model.Named(name: "idle_timeout_ms", type: Types.Type.Int),
        Model.Named(name: "max_connections", type: Types.Type.Int),
        Model.Named(name: "max_body_bytes", type: Types.Type.Int),
        Model.Named(name: "ca_file", type: Types.Type.String),
      ],
    ),
    Model.Record(
      name: "HttpRequest",
      fields: [
        Model.Named(name: "method", type: Types.Type.String),
        Model.Named(name: "target", type: Types.Type.String),
        Model.Named(name: "path", type: Types.Type.String),
        Model.Named(name: "headers", type: Types.Type.List(Types.Type.Struct("Header"))),
        Model.Named(name: "body", type: Types.Type.String),
      ],
    ),
    Model.Record(
      name: "HttpResponse",
      fields: [
        Model.Named(name: "status", type: Types.Type.Int),
        Model.Named(name: "headers", type: Types.Type.List(Types.Type.Struct("Header"))),
        Model.Named(name: "body", type: Types.Type.String),
      ],
    ),
    Model.Record(
      name: "HttpServerOptions",
      fields: [
        Model.Named(name: "request_timeout_ms", type: Types.Type.Int),
        Model.Named(name: "idle_timeout_ms", type: Types.Type.Int),
        Model.Named(name: "max_connections", type: Types.Type.Int),
        Model.Named(name: "max_body_bytes", type: Types.Type.Int),
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
        Model.Named(name: "headers", type: Types.Type.List(Types.Type.Struct("Header"))),
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
        Model.Named(name: "body", type: Types.Type.String),
        Model.Named(name: "deadline", type: Types.Type.Int),
        Model.Named(name: "reply", type: Types.Type.Channel(Types.Type.Result(Types.Type.Struct("HttpResponse")))),
        Model.Named(name: "worker", type: Types.Type.Int),
        Model.Named(name: "kept", type: Types.Type.Bool),
      ],
    ),
    Model.Record(
      name: "HttpWire.Reply",
      fields: [
        Model.Named(name: "head", type: Types.Type.String),
        Model.Named(name: "closes", type: Types.Type.Bool),
      ],
    ),
    Model.Record(
      name: "HttpWire.Response",
      fields: [
        Model.Named(name: "status", type: Types.Type.Int),
        Model.Named(name: "headers", type: Types.Type.List(Types.Type.Struct("Header"))),
        Model.Named(name: "length", type: Types.Type.Int),
        Model.Named(name: "chunked", type: Types.Type.Bool),
        Model.Named(name: "until_close", type: Types.Type.Bool),
        Model.Named(name: "closes", type: Types.Type.Bool),
        Model.Named(name: "buffered", type: Types.Type.Int),
        Model.Named(name: "ended", type: Types.Type.Bool),
      ],
    ),
    Model.Record(
      name: "HttpWire.Text",
      fields: [
        Model.Named(name: "text", type: Types.Type.String),
        Model.Named(name: "carry", type: Types.Type.List(Types.Type.Int)),
        Model.Named(name: "bytes", type: Types.Type.Int),
        Model.Named(name: "valid", type: Types.Type.Bool),
        Model.Named(name: "buffered", type: Types.Type.Int),
        Model.Named(name: "ended", type: Types.Type.Bool),
      ],
    ),
    Model.Record(
      name: "LogEvent",
      fields: [
        Model.Named(name: "level", type: Types.Type.Enum("LogLevel", [])),
        Model.Named(name: "message", type: Types.Type.String),
        Model.Named(name: "fields", type: Types.Type.Map(Types.Type.String, Types.Type.String)),
        Model.Named(name: "time_ms", type: Types.Type.Int),
        Model.Named(name: "task", type: Types.Type.Int),
      ],
    ),
    Model.Record(
      name: "ProcessOutput",
      fields: [
        Model.Named(name: "stdout", type: Types.Type.String),
        Model.Named(name: "stderr", type: Types.Type.String),
        Model.Named(name: "truncated", type: Types.Type.Bool),
      ],
    ),
  ]

## The builtin enums, whose variants are written without an import.
export ENUMS: List[Model.EnumDef] = [
    Model.EnumDef(
      name: "Await",
      parameters: ["T"],
      variants: [
        Model.Variant(name: "Done", payload: [Types.Type.Var("T")]),
        Model.Variant(name: "TimedOut", payload: []),
      ],
    ),
    Model.EnumDef(
      name: "LogLevel",
      parameters: [],
      variants: [
        Model.Variant(name: "Debug", payload: []),
        Model.Variant(name: "Info", payload: []),
        Model.Variant(name: "Warning", payload: []),
        Model.Variant(name: "Error", payload: []),
      ],
    ),
  ]

## The handle types a task can be given with Task.spawn_owning.
export HANDLE_TYPES: List[String] = ["Socket", "Listener", "HttpServer", "FileHandle", "Process"]

## The builtin types with no structure: handles and TestCase.
export OPAQUE_TYPES: List[String] = [
  "Socket", "Listener", "HttpClient", "HttpServer", "FileHandle", "Process", "TestCase",
]

## The type names no declaration or import alias may take.
export RESERVED_TYPE_NAMES: List[String] = [
    "Await",
    "Bool",
    "Channel",
    "Crypto",
    "Dir",
    "File",
    "FileHandle",
    "FileInfo",
    "Float",
    "Fn",
    "Header",
    "HttpClient",
    "HttpClientOptions",
    "HttpRequest",
    "HttpResponse",
    "HttpServer",
    "HttpServerOptions",
    "HttpWire",
    "IO",
    "Int",
    "JSON",
    "Json",
    "Lazy",
    "List",
    "Listener",
    "LogEvent",
    "LogLevel",
    "LogRegistry",
    "Map",
    "Nil",
    "Path",
    "Process",
    "ProcessOutput",
    "Profile",
    "Random",
    "Range",
    "Result",
    "Set",
    "Socket",
    "String",
    "System",
    "TCP",
    "TLS",
    "Task",
    "Test",
    "TestCase",
    "Time",
    "Void",
  ]

## The modules only std/ may call: each name with the std module that wraps it and the alias its help shows.
export STD_ONLY_IMPORTS: Map[String, List[String]] = {
  "HttpWire": ["std/http", "HTTP"],
  "LogRegistry": ["std/logger", "Logger"],
}

ROWS_1: List[Model.Builtin] = [
    Model.Builtin(
      name: "Channel.close",
      parameters: [Model.Named(name: "channel", type: Types.Type.Channel(Types.Type.Var("T")))],
      result: Types.Type.Void,
      rule: Model.Rule.ChannelTarget,
      implementation: "Channel.close",
      effects: ["concurrency"],
      description: "Close a channel idempotently; waiting tasks wake, and received values still drain; VM only.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Channel.closed?",
      parameters: [Model.Named(name: "channel", type: Types.Type.Channel(Types.Type.Var("T")))],
      result: Types.Type.Bool,
      rule: Model.Rule.ChannelTarget,
      implementation: "Channel.closed?",
      effects: [],
      description: "True once the channel is closed and every value was taken; VM only.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Channel.lazy",
      parameters: [
        Model.Named(name: "channel", type: Types.Type.Channel(Types.Type.Var("A"))),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Lazy(Types.Type.Var("A")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: (
        "Source: the values of the channel until it is closed and drained; each wait for a value obeys timeout_ms, " +
        "and a timeout ends the terminal with error(\"channel: timed out\"); VM only."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "Channel.new",
      parameters: [Model.Named(name: "capacity", type: Types.Type.Int)],
      result: Types.Type.Channel(Types.Type.Var("T")),
      rule: Model.Rule.ChannelNew,
      implementation: "Channel.new",
      effects: [],
      description: "Create a channel that holds 1 to 1048576 values; needs an expected Channel[T] type; VM only.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Channel.recv",
      parameters: [
        Model.Named(name: "channel", type: Types.Type.Channel(Types.Type.Var("T"))),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Var("T")),
      rule: Model.Rule.ChannelRecv,
      implementation: "Channel.recv",
      effects: ["concurrency"],
      description: (
        "Take the oldest value; wait up to timeout_ms; error(\"channel: closed\") once closed and empty, " +
        "error(\"channel: timed out\"); VM only."
      ),
      alternatives: [],
    ),
  ]

ROWS_2: List[Model.Builtin] = [
    Model.Builtin(
      name: "Channel.send",
      parameters: [
        Model.Named(name: "channel", type: Types.Type.Channel(Types.Type.Var("T"))),
        Model.Named(name: "value", type: Types.Type.Var("T")),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.ChannelSend,
      implementation: "Channel.send",
      effects: ["concurrency"],
      description: (
        "Add a value in order; wait for room up to timeout_ms; error(\"channel: closed\") or error(\"channel: timed " +
        "out\"); VM only."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "Crypto.sha256",
      parameters: [Model.Named(name: "data", type: Types.Type.List(Types.Type.Int))],
      result: Types.Type.List(Types.Type.Int),
      rule: Model.Rule.Plain,
      implementation: "Crypto.sha256",
      effects: [],
      description: "Hash bytes (each 0..255) with SHA-256 and return the 32 bytes of the digest; VM only.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Dir.list",
      parameters: [
        Model.Named(name: "path", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.List(Types.Type.String)),
      rule: Model.Rule.Plain,
      implementation: "Dir.list",
      effects: ["filesystem"],
      description: "List immediate entry names in sorted order.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Dir.mkdir",
      parameters: [
        Model.Named(name: "path", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "Dir.mkdir",
      effects: ["filesystem"],
      description: "Create a directory and missing parents; existing directories succeed.",
      alternatives: [],
    ),
  ]

ROWS_3: List[Model.Builtin] = [
    Model.Builtin(
      name: "Dir.mkdir_private",
      parameters: [
        Model.Named(name: "path", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "Dir.mkdir_private",
      effects: ["filesystem"],
      description: (
        "Create one directory only the current user can use; an existing path or a missing parent is an error; " +
        "VM only."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "File.append_text",
      parameters: [
        Model.Named(name: "path", type: Types.Type.String),
        Model.Named(name: "text", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "File.append_text",
      effects: ["filesystem"],
      description: "Append at most 1 MiB of UTF-8 text.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "File.close",
      parameters: [
        Model.Named(name: "handle", type: Types.Type.Opaque("FileHandle")),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "File.close",
      effects: ["filesystem"],
      description: "Flush and close a file handle idempotently.",
      alternatives: [],
    ),
  ]

ROWS_4: List[Model.Builtin] = [
    Model.Builtin(
      name: "File.each_line",
      parameters: [
        Model.Named(name: "path", type: Types.Type.String),
        Model.Named(name: "buffer_bytes", type: Types.Type.Int),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.String], Types.Type.Result(Types.Type.Void))),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "File.each_line",
      effects: ["filesystem"],
      description: (
        "Call the block once for each line of a file, in order, reading blocks of buffer_bytes (1024 to 16777216, " +
        "also the longest line); the block returns Result[Void] and an error stops the call; VM only."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "File.flush",
      parameters: [
        Model.Named(name: "handle", type: Types.Type.Opaque("FileHandle")),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "File.flush",
      effects: ["filesystem"],
      description: "Flush pending file output.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "File.foreach",
      parameters: [
        Model.Named(name: "path", type: Types.Type.String),
        Model.Named(name: "buffer_bytes", type: Types.Type.Int),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Lazy(Types.Type.String),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: (
        "Source: the lines of a file, read as File.each_line reads them; the file opens when a terminal starts and " +
        "closes before it returns; VM only."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "File.lstat",
      parameters: [
        Model.Named(name: "path", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Struct("FileInfo")),
      rule: Model.Rule.Plain,
      implementation: "File.lstat",
      effects: ["filesystem"],
      description: "Like File.stat, but a symbolic link is described itself and has kind \"link\"; VM only.",
      alternatives: [],
    ),
  ]

ROWS_5: List[Model.Builtin] = [
    Model.Builtin(
      name: "File.open",
      parameters: [
        Model.Named(name: "path", type: Types.Type.String),
        Model.Named(name: "mode", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Opaque("FileHandle")),
      rule: Model.Rule.Plain,
      implementation: "File.open",
      effects: ["filesystem"],
      description: (
        "Open a regular file for read, write, append or create_private with a deadline; create_private makes a new " +
        "file only the current user can use and fails when the path exists."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "File.read_bytes",
      parameters: [
        Model.Named(name: "handle", type: Types.Type.Opaque("FileHandle")),
        Model.Named(name: "max_bytes", type: Types.Type.Int),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.List(Types.Type.Int)),
      rule: Model.Rule.Plain,
      implementation: "File.read_bytes",
      effects: ["filesystem"],
      description: "Read up to max_bytes; empty means EOF.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "File.read_line",
      parameters: [
        Model.Named(name: "handle", type: Types.Type.Opaque("FileHandle")),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "File.read_line",
      effects: ["filesystem"],
      description: "Read one bounded UTF-8 line, removing LF or CRLF.",
      alternatives: [],
    ),
  ]

ROWS_6: List[Model.Builtin] = [
    Model.Builtin(
      name: "File.read_text",
      parameters: [
        Model.Named(name: "path", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "File.read_text",
      effects: ["filesystem"],
      description: "Read and strictly decode at most 1 MiB of UTF-8 text.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "File.stat",
      parameters: [
        Model.Named(name: "path", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Struct("FileInfo")),
      rule: Model.Rule.Plain,
      implementation: "File.stat",
      effects: ["filesystem"],
      description: (
        "Return the kind, byte size, modification time, permission bits and owner of a file, following symbolic " +
        "links."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "File.try_lock",
      parameters: [
        Model.Named(name: "handle", type: Types.Type.Opaque("FileHandle")),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Bool),
      rule: Model.Rule.Plain,
      implementation: "File.try_lock",
      effects: ["filesystem"],
      description: (
        "Take an exclusive lock on the open regular file without waiting: ok(true) when taken, ok(false) when " +
        "another handle or process holds it; the lock lasts until the handle is closed or the process ends; VM only."
      ),
      alternatives: [],
    ),
  ]

ROWS_7: List[Model.Builtin] = [
    Model.Builtin(
      name: "File.write",
      parameters: [
        Model.Named(name: "handle", type: Types.Type.Opaque("FileHandle")),
        Model.Named(name: "text", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "File.write",
      effects: ["filesystem"],
      description: "Write UTF-8 text, at most 1 MiB per call.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "File.write_bytes",
      parameters: [
        Model.Named(name: "handle", type: Types.Type.Opaque("FileHandle")),
        Model.Named(name: "bytes", type: Types.Type.List(Types.Type.Int)),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "File.write_bytes",
      effects: ["filesystem"],
      description: "Write bytes 0..255, at most 1 MiB per call.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "File.write_text",
      parameters: [
        Model.Named(name: "path", type: Types.Type.String),
        Model.Named(name: "text", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "File.write_text",
      effects: ["filesystem"],
      description: "Overwrite a file with at most 1 MiB of UTF-8 text.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Float.from_bits",
      parameters: [Model.Named(name: "bits", type: Types.Type.Int)],
      result: Types.Type.Float,
      rule: Model.Rule.Plain,
      implementation: "Float.from_bits",
      effects: [],
      description: "Read the 64 bits of an Int as a binary64 Float; any NaN pattern gives NaN.",
      alternatives: [],
    ),
  ]

ROWS_8: List[Model.Builtin] = [
    Model.Builtin(
      name: "Float.from_bits32",
      parameters: [Model.Named(name: "bits", type: Types.Type.Int)],
      result: Types.Type.Float,
      rule: Model.Rule.Plain,
      implementation: "Float.from_bits32",
      effects: [],
      description: "Read 32 bits as a binary32 and widen it exactly; bits outside 0 to 4294967295 halt.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Float.from_int",
      parameters: [Model.Named(name: "n", type: Types.Type.Int)],
      result: Types.Type.Float,
      rule: Model.Rule.Plain,
      implementation: "Float.from_int",
      effects: [],
      description: "Convert an Int to the nearest Float.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Float.to_bits",
      parameters: [Model.Named(name: "x", type: Types.Type.Float)],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "Float.to_bits",
      effects: [],
      description: "The 64 IEEE 754 binary64 bits as an Int; every NaN gives the canonical 9221120237041090560.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Float.to_bits32",
      parameters: [Model.Named(name: "x", type: Types.Type.Float)],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "Float.to_bits32",
      effects: [],
      description: (
        "Round to binary32 (ties to even) and give its 32 bits as an Int from 0 to 4294967295; every NaN gives " +
        "2143289344."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "Float.to_int",
      parameters: [Model.Named(name: "x", type: Types.Type.Float)],
      result: Types.Type.Result(Types.Type.Int),
      rule: Model.Rule.Plain,
      implementation: "Float.to_int",
      effects: [],
      description: "Truncate toward zero; NaN, infinity or overflow return an error.",
      alternatives: [],
    ),
  ]

ROWS_9: List[Model.Builtin] = [
    Model.Builtin(
      name: "Float.to_int!",
      parameters: [Model.Named(name: "x", type: Types.Type.Float)],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "Float.to_int!",
      effects: [],
      description: "Truncate toward zero; halt on NaN, infinity or overflow.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "FrontEnd.hand_off",
      parameters: [
        Model.Named(name: "program", type: Types.Type.List(Types.Type.Int)),
        Model.Named(name: "options", type: Types.Type.List(Types.Type.String)),
        Model.Named(name: "arguments", type: Types.Type.List(Types.Type.String)),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "FrontEnd.hand_off",
      effects: ["process"],
      description: (
        "Front end only: hand the compiled program, the VM options and the program arguments to the VM, which ends " +
        "this run and runs the program in a new one; it returns an error only when an argument cannot be passed on " +
        "(a byte outside 0 to 255, or a character 0 in a word). Any other program fails with RUNTIME-FRONT-END-ONLY."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "FrontEnd.std_source",
      parameters: [Model.Named(name: "path", type: Types.Type.String)],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "FrontEnd.std_source",
      effects: ["process"],
      description: (
        "Front end only: the text of an embedded std/ source, by its path in stdlib/ such as queue.agc or " +
        "bdd/gherkin.agc; an unknown path is an error. Any other program fails with RUNTIME-FRONT-END-ONLY."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "FrontEnd.stdin_bytes",
      parameters: [],
      result: Types.Type.Result(Types.Type.List(Types.Type.Int)),
      rule: Model.Rule.Plain,
      implementation: "FrontEnd.stdin_bytes",
      effects: ["process"],
      description: (
        "Front end only: standard input as bytes, read to its end (a later call reads on from there); more than " +
        "16 MiB, or a read that fails, is an error. The front end has no input stream otherwise. Any other program " +
        "fails with RUNTIME-FRONT-END-ONLY."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.accept",
      parameters: [Model.Named(name: "server", type: Types.Type.Opaque("HttpServer"))],
      result: Types.Type.Result(Types.Type.Opaque("Socket")),
      rule: Model.Rule.Plain,
      implementation: "HttpWire.accept",
      effects: ["network"],
      description: "Internal to std/http: wait for a free slot and the next connection.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.awaited?",
      parameters: [
        Model.Named(name: "reply", type: Types.Type.Channel(Types.Type.Result(Types.Type.Struct("HttpResponse")))),
      ],
      result: Types.Type.Bool,
      rule: Model.Rule.Plain,
      implementation: "HttpWire.awaited?",
      effects: [],
      description: "Internal to std/http: false once a receiver that parked on reply left without a value.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.chunk",
      parameters: [
        Model.Named(name: "state", type: Types.Type.Struct("HttpWire.Chunk")),
        Model.Named(name: "data", type: Types.Type.List(Types.Type.Int)),
        Model.Named(name: "from", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Struct("HttpWire.Chunk")),
      rule: Model.Rule.Plain,
      implementation: "HttpWire.chunk",
      effects: [],
      description: (
        "Internal to std/http: decode the chunked framing in data from offset from; runs holds the start and " +
        "length of each piece of body; the error is the answer status and the reason."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.chunk_read",
      parameters: [
        Model.Named(name: "state", type: Types.Type.Struct("HttpWire.Chunk")),
        Model.Named(name: "bytes", type: Types.Type.Int),
      ],
      result: Types.Type.Struct("HttpWire.Chunk"),
      rule: Model.Rule.Plain,
      implementation: "HttpWire.chunk_read",
      effects: [],
      description: "Internal to std/http: the state after std read bytes of chunk data itself, at most remaining.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.chunked",
      parameters: [Model.Named(name: "max_body_bytes", type: Types.Type.Int)],
      result: Types.Type.Struct("HttpWire.Chunk"),
      rule: Model.Rule.Plain,
      implementation: "HttpWire.chunked",
      effects: [],
      description: "Internal to std/http: the state that starts a chunked body.",
      alternatives: [],
    ),
  ]

ROWS_10: List[Model.Builtin] = [
    Model.Builtin(
      name: "HttpWire.clean_eof?",
      parameters: [Model.Named(name: "socket", type: Types.Type.Opaque("Socket"))],
      result: Types.Type.Bool,
      rule: Model.Rule.Plain,
      implementation: "HttpWire.clean_eof?",
      effects: ["network"],
      description: "Internal to std/http: whether the end of input a read reported was clean (TLS: close_notify).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.close_server",
      parameters: [Model.Named(name: "server", type: Types.Type.Opaque("HttpServer"))],
      result: Types.Type.Void,
      rule: Model.Rule.Plain,
      implementation: "HttpWire.close_server",
      effects: ["network"],
      description: "Internal to std/http: close the listener and cancel the server's tasks.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.close_write",
      parameters: [Model.Named(name: "socket", type: Types.Type.Opaque("Socket"))],
      result: Types.Type.Void,
      rule: Model.Rule.Plain,
      implementation: "HttpWire.close_write",
      effects: ["network"],
      description: "Internal to std/http: close the write side of a socket once its output is sent; reads go on.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.connect_tls",
      parameters: [
        Model.Named(name: "client", type: Types.Type.Opaque("HttpClient")),
        Model.Named(name: "host", type: Types.Type.String),
        Model.Named(name: "port", type: Types.Type.Int),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Opaque("Socket")),
      rule: Model.Rule.Plain,
      implementation: "HttpWire.connect_tls",
      effects: ["network"],
      description: "Internal to std/http: TLS.connect with the client's ca_file, on its shared TLS context.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.drop_tls",
      parameters: [Model.Named(name: "client", type: Types.Type.Opaque("HttpClient"))],
      result: Types.Type.Void,
      rule: Model.Rule.Plain,
      implementation: "HttpWire.drop_tls",
      effects: ["network"],
      description: "Internal to std/http: give back the client's TLS context; open connections keep theirs.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.encode_request",
      parameters: [
        Model.Named(name: "scheme", type: Types.Type.String),
        Model.Named(name: "host", type: Types.Type.String),
        Model.Named(name: "port", type: Types.Type.Int),
        Model.Named(name: "method", type: Types.Type.String),
        Model.Named(name: "target", type: Types.Type.String),
        Model.Named(name: "headers", type: Types.Type.List(Types.Type.Struct("Header"))),
        Model.Named(name: "body", type: Types.Type.String),
        Model.Named(name: "max_body_bytes", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "HttpWire.encode_request",
      effects: [],
      description: (
        "Internal to std/http: the text of a request head with Host and Content-Length, or the reason the " +
        "request cannot be sent."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.encode_response",
      parameters: [
        Model.Named(name: "request", type: Types.Type.Struct("HttpRequest")),
        Model.Named(name: "response", type: Types.Type.Struct("HttpResponse")),
        Model.Named(name: "now_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Struct("HttpWire.Reply")),
      rule: Model.Rule.Plain,
      implementation: "HttpWire.encode_response",
      effects: [],
      description: (
        "Internal to std/http: the text of a response head with Content-Length and Date, and whether the " +
        "connection closes after it, or the reason it cannot be sent."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.error_answer",
      parameters: [Model.Named(name: "status", type: Types.Type.Int)],
      result: Types.Type.String,
      rule: Model.Rule.Plain,
      implementation: "HttpWire.error_answer",
      effects: [],
      description: "Internal to std/http: the error answer with this status, an empty body and Connection: close.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.jobs",
      parameters: [Model.Named(name: "client", type: Types.Type.Opaque("HttpClient"))],
      result: Types.Type.Channel(Types.Type.Struct("HttpWire.Job")),
      rule: Model.Rule.Plain,
      implementation: "HttpWire.jobs",
      effects: [],
      description: "Internal to std/http: the jobs channel of a client's owner task.",
      alternatives: [],
    ),
  ]

ROWS_11: List[Model.Builtin] = [
    Model.Builtin(
      name: "HttpWire.local_port",
      parameters: [Model.Named(name: "server", type: Types.Type.Opaque("HttpServer"))],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "HttpWire.local_port",
      effects: ["network"],
      description: "Internal to std/http: the server's listening port.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.options",
      parameters: [Model.Named(name: "client", type: Types.Type.Opaque("HttpClient"))],
      result: Types.Type.Struct("HttpClientOptions"),
      rule: Model.Rule.Plain,
      implementation: "HttpWire.options",
      effects: [],
      description: "Internal to std/http: the options a client was made with.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.read_head",
      parameters: [
        Model.Named(name: "socket", type: Types.Type.Opaque("Socket")),
        Model.Named(name: "rest", type: Types.Type.List(Types.Type.Int)),
        Model.Named(name: "max_body_bytes", type: Types.Type.Int),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Struct("HttpWire.Head")),
      rule: Model.Rule.Plain,
      implementation: "HttpWire.read_head",
      effects: ["network"],
      description: (
        "Internal to std/http: put rest back in front of the input, then read and parse the next request head; " +
        "a bad head has the answer's status and reason (status 0 for a good one)."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.read_response",
      parameters: [
        Model.Named(name: "socket", type: Types.Type.Opaque("Socket")),
        Model.Named(name: "head_only", type: Types.Type.Bool),
        Model.Named(name: "max_body_bytes", type: Types.Type.Int),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Struct("HttpWire.Response")),
      rule: Model.Rule.Plain,
      implementation: "HttpWire.read_response",
      effects: ["network"],
      description: (
        "Internal to std/http: read and parse the next response head, with the framing of a response to HEAD " +
        "when head_only; an interim (1xx) head comes back as it is."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.read_text",
      parameters: [
        Model.Named(name: "socket", type: Types.Type.Opaque("Socket")),
        Model.Named(name: "max_bytes", type: Types.Type.Int),
        Model.Named(name: "carry", type: Types.Type.List(Types.Type.Int)),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Struct("HttpWire.Text")),
      rule: Model.Rule.Plain,
      implementation: "HttpWire.read_text",
      effects: ["network"],
      description: (
        "Internal to std/http: read the bytes available, at most max_bytes (0..1048576; 0 does not wait), as " +
        "UTF-8 text after carry; bytes is 0 at the end of input, valid is false for bytes that are not UTF-8, " +
        "buffered counts the input bytes left unread, and ended is true once the input has ended or failed."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.server",
      parameters: [
        Model.Named(name: "listener", type: Types.Type.Opaque("Listener")),
        Model.Named(name: "max_connections", type: Types.Type.Int),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Opaque("HttpServer")], Types.Type.Void)),
      ],
      result: Types.Type.Opaque("HttpServer"),
      rule: Model.Rule.Plain,
      implementation: "HttpWire.server",
      effects: ["network"],
      description: "Internal to std/http: make a server's task group on a listener and run f, its accept loop, in it.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.service",
      parameters: [
        Model.Named(name: "jobs", type: Types.Type.Channel(Types.Type.Struct("HttpWire.Job"))),
        Model.Named(name: "options", type: Types.Type.Struct("HttpClientOptions")),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Opaque("HttpClient")], Types.Type.Void)),
      ],
      result: Types.Type.Opaque("HttpClient"),
      rule: Model.Rule.Plain,
      implementation: "HttpWire.service",
      effects: ["concurrency"],
      description: (
        "Internal to std/http: run f(client), a client's owner task, outside every caller's task tree, as the " +
        "owner of jobs; the client keeps jobs and options."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.spawn",
      parameters: [
        Model.Named(name: "server", type: Types.Type.Opaque("HttpServer")),
        Model.Named(name: "socket", type: Types.Type.Opaque("Socket")),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Opaque("Socket")], Types.Type.Void)),
      ],
      result: Types.Type.Void,
      rule: Model.Rule.Plain,
      implementation: "HttpWire.spawn",
      effects: ["network"],
      description: "Internal to std/http: run a connection task in the server's group.",
      alternatives: [],
    ),
  ]

ROWS_12: List[Model.Builtin] = [
    Model.Builtin(
      name: "HttpWire.text",
      parameters: [
        Model.Named(name: "carry", type: Types.Type.List(Types.Type.Int)),
        Model.Named(name: "data", type: Types.Type.List(Types.Type.Int)),
        Model.Named(name: "runs", type: Types.Type.List(Types.Type.Int)),
      ],
      result: Types.Type.Struct("HttpWire.Text"),
      rule: Model.Rule.Plain,
      implementation: "HttpWire.text",
      effects: [],
      description: (
        "Internal to std/http: the UTF-8 text of carry and the runs of data (start, length pairs); an " +
        "unfinished last character is the new carry, and valid is false for bytes that are not UTF-8."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "HttpWire.wait",
      parameters: [Model.Named(name: "server", type: Types.Type.Opaque("HttpServer"))],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "HttpWire.wait",
      effects: ["network"],
      description: "Internal to std/http: wait until the server is closed.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "IO.eof?",
      parameters: [],
      result: Types.Type.Bool,
      rule: Model.Rule.Plain,
      implementation: "IO.eof?",
      effects: ["stdin"],
      description: "Peek for EOF without consuming a byte; may block, not a readiness poll.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "IO.flush",
      parameters: [],
      result: Types.Type.Void,
      rule: Model.Rule.Plain,
      implementation: "IO.flush",
      effects: ["stdout"],
      description: "Flush buffered standard output.",
      alternatives: [],
    ),
  ]

ROWS_13: List[Model.Builtin] = [
    Model.Builtin(
      name: "IO.gets",
      parameters: [],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "IO.gets",
      effects: ["stdin"],
      description: "Read a line as a Result; EOF is an error value.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "IO.gets!",
      parameters: [],
      result: Types.Type.String,
      rule: Model.Rule.Plain,
      implementation: "IO.gets!",
      effects: ["stdin"],
      description: "Read a line; halt at EOF.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "IO.inspect",
      parameters: [Model.Named(name: "value", type: Types.Type.Var("T"))],
      result: Types.Type.Var("T"),
      rule: Model.Rule.Identity,
      implementation: "IO.inspect",
      effects: ["stdout"],
      description: "Print a stable debug form and return the value.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "IO.print",
      parameters: [Model.Named(name: "value", type: Types.Type.Var("T"))],
      result: Types.Type.Void,
      rule: Model.Rule.Show,
      implementation: "IO.print",
      effects: ["stdout"],
      description: "Write a value without a newline; non-String values print as in interpolation.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "IO.puts",
      parameters: [Model.Named(name: "value", type: Types.Type.Var("T"))],
      result: Types.Type.Void,
      rule: Model.Rule.Show,
      implementation: "puts",
      effects: ["stdout"],
      description: "Write a value and a newline; non-String values print as in interpolation.",
      alternatives: [],
    ),
  ]

ROWS_14: List[Model.Builtin] = [
    Model.Builtin(
      name: "IO.read",
      parameters: [],
      result: Types.Type.String,
      rule: Model.Rule.Plain,
      implementation: "IO.read",
      effects: ["stdin"],
      description: "Read all remaining text until EOF.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "IO.read_bytes",
      parameters: [Model.Named(name: "count", type: Types.Type.Int)],
      result: Types.Type.Result(Types.Type.List(Types.Type.Int)),
      rule: Model.Rule.Plain,
      implementation: "IO.read_bytes",
      effects: ["stdin"],
      description: "Read count bytes or fewer at EOF; count must be 0..1048576. EOF gives an empty list.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "IO.warn",
      parameters: [Model.Named(name: "value", type: Types.Type.Var("T"))],
      result: Types.Type.Void,
      rule: Model.Rule.Show,
      implementation: "IO.warn",
      effects: ["stderr"],
      description: "Write a value and a newline to stderr; non-String values print as in interpolation.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Int.bit_and",
      parameters: [Model.Named(name: "a", type: Types.Type.Int), Model.Named(name: "b", type: Types.Type.Int)],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "Int.bit_and",
      effects: [],
      description: "Bitwise and of the 64-bit two's complement forms.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Int.bit_not",
      parameters: [Model.Named(name: "a", type: Types.Type.Int)],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "Int.bit_not",
      effects: [],
      description: "Flip every bit; the same as -1 - a.",
      alternatives: [],
    ),
  ]

ROWS_15: List[Model.Builtin] = [
    Model.Builtin(
      name: "Int.bit_or",
      parameters: [Model.Named(name: "a", type: Types.Type.Int), Model.Named(name: "b", type: Types.Type.Int)],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "Int.bit_or",
      effects: [],
      description: "Bitwise or of the 64-bit two's complement forms.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Int.bit_xor",
      parameters: [Model.Named(name: "a", type: Types.Type.Int), Model.Named(name: "b", type: Types.Type.Int)],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "Int.bit_xor",
      effects: [],
      description: "Bitwise exclusive or of the 64-bit two's complement forms.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Int.downto",
      parameters: [
        Model.Named(name: "from", type: Types.Type.Int),
        Model.Named(name: "to", type: Types.Type.Int),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Int], Types.Type.Void)),
      ],
      result: Types.Type.Void,
      rule: Model.Rule.Plain,
      implementation: "Int.downto",
      effects: [],
      description: "Call f with from down to to; nothing when to > from.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Int.shift_left",
      parameters: [Model.Named(name: "a", type: Types.Type.Int), Model.Named(name: "count", type: Types.Type.Int)],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "Int.shift_left",
      effects: [],
      description: (
        "Shift bits left; bits that leave the top are dropped, so it wraps; a count of 64 or more gives 0; a " +
        "negative count halts."
      ),
      alternatives: [],
    ),
  ]

ROWS_16: List[Model.Builtin] = [
    Model.Builtin(
      name: "Int.shift_right",
      parameters: [Model.Named(name: "a", type: Types.Type.Int), Model.Named(name: "count", type: Types.Type.Int)],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "Int.shift_right",
      effects: [],
      description: (
        "Arithmetic shift right, copying the sign bit; a count of 64 or more gives 0 or -1; a negative count halts."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "Int.shift_right_unsigned",
      parameters: [Model.Named(name: "a", type: Types.Type.Int), Model.Named(name: "count", type: Types.Type.Int)],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "Int.shift_right_unsigned",
      effects: [],
      description: "Logical shift right, bringing in zeros; a count of 64 or more gives 0; a negative count halts.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Int.times",
      parameters: [
        Model.Named(name: "n", type: Types.Type.Int),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Int], Types.Type.Void)),
      ],
      result: Types.Type.Void,
      rule: Model.Rule.Plain,
      implementation: "Int.times",
      effects: [],
      description: "Call f with 0 to n - 1; nothing when n <= 0.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Int.upto",
      parameters: [
        Model.Named(name: "from", type: Types.Type.Int),
        Model.Named(name: "to", type: Types.Type.Int),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Int], Types.Type.Void)),
      ],
      result: Types.Type.Void,
      rule: Model.Rule.Plain,
      implementation: "Int.upto",
      effects: [],
      description: "Call f with from up to to; nothing when to < from.",
      alternatives: [],
    ),
  ]

ROWS_17: List[Model.Builtin] = [
    Model.Builtin(
      name: "JSON.array",
      parameters: [Model.Named(name: "items", type: Types.Type.List(Types.Type.Json))],
      result: Types.Type.Json,
      rule: Model.Rule.Plain,
      implementation: "JSON.array",
      effects: [],
      description: "Build a JSON array from JSON values.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "JSON.at",
      parameters: [Model.Named(name: "j", type: Types.Type.Json), Model.Named(name: "index", type: Types.Type.Int)],
      result: Types.Type.Result(Types.Type.Json),
      rule: Model.Rule.Plain,
      implementation: "JSON.at",
      effects: [],
      description: "Read an array element; wrong kind or bad index returns an error.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "JSON.bool",
      parameters: [Model.Named(name: "j", type: Types.Type.Json)],
      result: Types.Type.Result(Types.Type.Bool),
      rule: Model.Rule.Plain,
      implementation: "JSON.bool",
      effects: [],
      description: "Extract a JSON boolean; wrong kind returns an error.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "JSON.decode",
      parameters: [
        Model.Named(name: "s", type: Types.Type.String),
        Model.Named(name: "type", type: Types.Type.Var("T")),
      ],
      result: Types.Type.Result(Types.Type.Var("T")),
      rule: Model.Rule.JsonDecode,
      implementation: "JSON.decode",
      effects: [],
      description: "Decode JSON into a named struct; invalid data returns an error.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "JSON.encode",
      parameters: [Model.Named(name: "value", type: Types.Type.Var("T"))],
      result: Types.Type.String,
      rule: Model.Rule.JsonEncode,
      implementation: "JSON.encode",
      effects: [],
      description: "Encode JSON-compatible values; halt on non-finite Float values.",
      alternatives: [],
    ),
  ]

ROWS_18: List[Model.Builtin] = [
    Model.Builtin(
      name: "JSON.float",
      parameters: [Model.Named(name: "j", type: Types.Type.Json)],
      result: Types.Type.Result(Types.Type.Float),
      rule: Model.Rule.Plain,
      implementation: "JSON.float",
      effects: [],
      description: "Extract a finite Float from a JSON number; wrong kind or overflow returns an error.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "JSON.from",
      parameters: [Model.Named(name: "value", type: Types.Type.Var("T"))],
      result: Types.Type.Json,
      rule: Model.Rule.JsonFrom,
      implementation: "JSON.from",
      effects: [],
      description: "Convert JSON-compatible data to a JSON value.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "JSON.get",
      parameters: [Model.Named(name: "j", type: Types.Type.Json), Model.Named(name: "key", type: Types.Type.String)],
      result: Types.Type.Result(Types.Type.Json),
      rule: Model.Rule.Plain,
      implementation: "JSON.get",
      effects: [],
      description: "Read an object member; wrong kind or missing key returns an error.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "JSON.int",
      parameters: [Model.Named(name: "j", type: Types.Type.Json)],
      result: Types.Type.Result(Types.Type.Int),
      rule: Model.Rule.Plain,
      implementation: "JSON.int",
      effects: [],
      description: "Extract a signed 64-bit JSON integer; wrong kind or overflow returns an error.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "JSON.list",
      parameters: [Model.Named(name: "j", type: Types.Type.Json)],
      result: Types.Type.Result(Types.Type.List(Types.Type.Json)),
      rule: Model.Rule.Plain,
      implementation: "JSON.list",
      effects: [],
      description: "Extract an array as a list of opaque JSON values; wrong kind returns an error.",
      alternatives: [],
    ),
  ]

ROWS_19: List[Model.Builtin] = [
    Model.Builtin(
      name: "JSON.null",
      parameters: [],
      result: Types.Type.Json,
      rule: Model.Rule.Plain,
      implementation: "JSON.null",
      effects: [],
      description: "Return JSON null.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "JSON.null?",
      parameters: [Model.Named(name: "value", type: Types.Type.Json)],
      result: Types.Type.Bool,
      rule: Model.Rule.Plain,
      implementation: "JSON.null?",
      effects: [],
      description: "Test for JSON null.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "JSON.object",
      parameters: [Model.Named(name: "fields", type: Types.Type.Map(Types.Type.String, Types.Type.Json))],
      result: Types.Type.Json,
      rule: Model.Rule.Plain,
      implementation: "JSON.object",
      effects: [],
      description: "Build a JSON object from JSON values.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "JSON.parse",
      parameters: [Model.Named(name: "s", type: Types.Type.String)],
      result: Types.Type.Result(Types.Type.Json),
      rule: Model.Rule.Plain,
      implementation: "JSON.parse",
      effects: [],
      description: "Parse exactly one JSON value; invalid input returns an error.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "JSON.schema",
      parameters: [Model.Named(name: "type", type: Types.Type.Var("T"))],
      result: Types.Type.Json,
      rule: Model.Rule.JsonSchema,
      implementation: "JSON.schema",
      effects: [],
      description: "Describe a decodable struct with JSON Schema.",
      alternatives: [],
    ),
  ]

ROWS_20: List[Model.Builtin] = [
    Model.Builtin(
      name: "JSON.string",
      parameters: [Model.Named(name: "j", type: Types.Type.Json)],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "JSON.string",
      effects: [],
      description: "Extract a JSON string; wrong kind returns an error.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Lazy.chunk_while",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A"), Types.Type.Var("A")], Types.Type.Bool)),
      ],
      result: Types.Type.Lazy(Types.Type.List(Types.Type.Var("A"))),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Lazy step: group runs of items, a new group where f(previous, item) is false.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Lazy.drop",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "count", type: Types.Type.Int),
      ],
      result: Types.Type.Lazy(Types.Type.Var("A")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Lazy step: skip the first count items; negative counts halt.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Lazy.drop_while",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Bool)),
      ],
      result: Types.Type.Lazy(Types.Type.Var("A")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Lazy step: skip items while f is true, then keep the rest.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Lazy.each",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Result(Types.Type.Void))),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Terminal: call f on each item in order; stops at the first error f returns, which is the result.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Lazy.each_cons",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "size", type: Types.Type.Int),
      ],
      result: Types.Type.Lazy(Types.Type.List(Types.Type.Var("A"))),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Lazy step: each window of size consecutive items; size below 1 halts.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Lazy.each_slice",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "size", type: Types.Type.Int),
      ],
      result: Types.Type.Lazy(Types.Type.List(Types.Type.Var("A"))),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Lazy step: slices of size items, the last one shorter; size below 1 halts.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Lazy.filter",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Bool)),
      ],
      result: Types.Type.Lazy(Types.Type.Var("A")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Lazy step: keep the items whose predicate is true.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Lazy.find",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Bool)),
      ],
      result: Types.Type.Result(Types.Type.Var("A")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Terminal: the first item f accepts, else error(\"not found\") when the source ends.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Lazy.first",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "count", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.List(Types.Type.Var("A"))),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Terminal: the first count items (fewer if the source ends); negative counts halt.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Lazy.flat_map",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.List(Types.Type.Var("B")))),
      ],
      result: Types.Type.Lazy(Types.Type.Var("B")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Lazy step: the items of the lists f returns, in order.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Lazy.map",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Var("B"))),
      ],
      result: Types.Type.Lazy(Types.Type.Var("B")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Lazy step: f applied to each item.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Lazy.produce",
      parameters: [
        Model.Named(name: "seed", type: Types.Type.Var("A")),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Var("A"))),
      ],
      result: Types.Type.Lazy(Types.Type.Var("A")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Endless source: seed, f(seed), f(f(seed)) ...; end it with take, take_while, first or find.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Lazy.reduce",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "initial", type: Types.Type.Var("B")),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("B"), Types.Type.Var("A")], Types.Type.Var("B"))),
      ],
      result: Types.Type.Result(Types.Type.Var("B")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Terminal: fold left from initial in order.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Lazy.take",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "count", type: Types.Type.Int),
      ],
      result: Types.Type.Lazy(Types.Type.Var("A")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Lazy step: at most count items, then the source stops; negative counts halt.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Lazy.take_while",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Bool)),
      ],
      result: Types.Type.Lazy(Types.Type.Var("A")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Lazy step: items while f is true; stops at the first false.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Lazy.to_a",
      parameters: [Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A")))],
      result: Types.Type.Result(Types.Type.List(Types.Type.Var("A"))),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Terminal: every item in a list; never ends on an endless source.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Lazy.with_index",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A"), Types.Type.Int], Types.Type.Var("B"))),
      ],
      result: Types.Type.Lazy(Types.Type.Var("B")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Lazy step: f(item, index) for each item, the index from 0.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Lazy.write_lines",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.String)),
        Model.Named(name: "path", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: ["filesystem"],
      description: (
        "Terminal: write each item and a line feed to a file, created or truncated; the file opens before the first " +
        "item is pulled and is flushed and closed before the terminal returns; VM only."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.all?",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Bool)),
      ],
      result: Types.Type.Bool,
      rule: Model.Rule.ListAll,
      implementation: "List.all?",
      effects: [],
      description: "True when f is true for every element; stops at the first false.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.any?",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Bool)),
      ],
      result: Types.Type.Bool,
      rule: Model.Rule.ListAny,
      implementation: "List.any?",
      effects: [],
      description: "True when f is true for some element; stops at the first true.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.append",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("T"))),
        Model.Named(name: "value", type: Types.Type.Var("T")),
      ],
      result: Types.Type.List(Types.Type.Var("T")),
      rule: Model.Rule.ListAppend,
      implementation: "List.append",
      effects: [],
      description: "Return a new list with this value appended; near constant time.",
      alternatives: [],
    ),
  ]

ROWS_21: List[Model.Builtin] = [
    Model.Builtin(
      name: "List.at",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("T"))),
        Model.Named(name: "index", type: Types.Type.Int),
      ],
      result: Types.Type.Var("T"),
      rule: Model.Rule.ListAt,
      implementation: "List.at",
      effects: [],
      description: "Read a zero-based index; invalid indexes halt; O(log32 n).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.concat",
      parameters: [
        Model.Named(name: "a", type: Types.Type.List(Types.Type.Var("T"))),
        Model.Named(name: "b", type: Types.Type.List(Types.Type.Var("T"))),
      ],
      result: Types.Type.List(Types.Type.Var("T")),
      rule: Model.Rule.ListConcat,
      implementation: "List.concat",
      effects: [],
      description: (
        "Concatenate two lists without changing either; O(length of b) when b has at most 32 items, else O(length " +
        "of a + b)."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.drop",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("T"))),
        Model.Named(name: "count", type: Types.Type.Int),
      ],
      result: Types.Type.List(Types.Type.Var("T")),
      rule: Model.Rule.ListCount,
      implementation: "List.drop",
      effects: [],
      description: "Drop up to count elements; negative counts halt.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.drop_while",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Bool)),
      ],
      result: Types.Type.List(Types.Type.Var("A")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Drop elements while f is true, then keep the rest; f stops being called at the first false; O(n).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.each",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Void)),
      ],
      result: Types.Type.Void,
      rule: Model.Rule.ListEach,
      implementation: "List.each",
      effects: [],
      description: "Call f on each element in order; returns nothing.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.each_slice",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A"))),
        Model.Named(name: "size", type: Types.Type.Int),
      ],
      result: Types.Type.List(Types.Type.List(Types.Type.Var("A"))),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Split into slices of size elements, the last one shorter; size below 1 halts; O(n).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.each_with_index",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A"), Types.Type.Int], Types.Type.Void)),
      ],
      result: Types.Type.Void,
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Call f(element, index) in order, the index from 0; returns nothing.",
      alternatives: [],
    ),
  ]

ROWS_22: List[Model.Builtin] = [
    Model.Builtin(
      name: "List.filter",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Bool)),
      ],
      result: Types.Type.List(Types.Type.Var("A")),
      rule: Model.Rule.ListFilter,
      implementation: "List.filter",
      effects: [],
      description: "Keep elements whose predicate is true, in order; O(n).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.find",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Bool)),
      ],
      result: Types.Type.Result(Types.Type.Var("A")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: (
        "The first element f accepts, else error(\"not found\"); f stops being called at the first " +
        "true; O(n)."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.flat_map",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.List(Types.Type.Var("B")))),
      ],
      result: Types.Type.List(Types.Type.Var("B")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Concatenate the lists f returns for each element, in order; O(total).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.group_by",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A"))),
        Model.Named(name: "key", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Var("K"))),
      ],
      result: Types.Type.Map(Types.Type.Var("K"), Types.Type.List(Types.Type.Var("A"))),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: (
        "Group elements by an Int or String key; keys in order of first appearance, elements in " +
        "order; O(n)."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.lazy",
      parameters: [Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A")))],
      result: Types.Type.Lazy(Types.Type.Var("A")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "A Lazy over the list: steps run only in a terminal, one item at a time.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.map",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Var("B"))),
      ],
      result: Types.Type.List(Types.Type.Var("B")),
      rule: Model.Rule.ListMap,
      implementation: "List.map",
      effects: [],
      description: "Map each element in order without changing the input; O(n).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.max_by",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A"))),
        Model.Named(name: "key", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Var("O"))),
      ],
      result: Types.Type.Result(Types.Type.Var("A")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: (
        "The element with the greatest Int, Float or String key, the first on ties; error(\"the " +
        "list is empty\") for an empty list; O(n)."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.min_by",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A"))),
        Model.Named(name: "key", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Var("O"))),
      ],
      result: Types.Type.Result(Types.Type.Var("A")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: (
        "The element with the least Int, Float or String key, the first on ties; error(\"the list " +
        "is empty\") for an empty list; O(n)."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.partition",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Bool)),
      ],
      result: Types.Type.List(Types.Type.List(Types.Type.Var("A"))),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Two lists, [accepted, rejected], each in order; f is called once per element; O(n).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.reduce",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A"))),
        Model.Named(name: "initial", type: Types.Type.Var("B")),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("B"), Types.Type.Var("A")], Types.Type.Var("B"))),
      ],
      result: Types.Type.Var("B"),
      rule: Model.Rule.ListReduce,
      implementation: "List.reduce",
      effects: [],
      description: "Fold left with f(accumulator, item); empty lists return initial; O(n).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.repeat",
      parameters: [
        Model.Named(name: "value", type: Types.Type.Var("T")),
        Model.Named(name: "count", type: Types.Type.Int),
      ],
      result: Types.Type.List(Types.Type.Var("T")),
      rule: Model.Rule.ListRepeat,
      implementation: "List.repeat",
      effects: [],
      description: "Repeat a value 0..1048576 times; invalid counts halt; O(n).",
      alternatives: [],
    ),
  ]

ROWS_23: List[Model.Builtin] = [
    Model.Builtin(
      name: "List.reverse",
      parameters: [Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("T")))],
      result: Types.Type.List(Types.Type.Var("T")),
      rule: Model.Rule.ListReverse,
      implementation: "List.reverse",
      effects: [],
      description: "Return a reversed list; O(n).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.set",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("T"))),
        Model.Named(name: "index", type: Types.Type.Int),
        Model.Named(name: "value", type: Types.Type.Var("T")),
      ],
      result: Types.Type.List(Types.Type.Var("T")),
      rule: Model.Rule.ListSet,
      implementation: "List.set",
      effects: [],
      description: "Return a new list with an element replaced; invalid indexes halt; O(log32 n).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.size",
      parameters: [Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("T")))],
      result: Types.Type.Int,
      rule: Model.Rule.ListSize,
      implementation: "List.size",
      effects: [],
      description: "Count list elements.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.sort",
      parameters: [Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("T")))],
      result: Types.Type.List(Types.Type.Var("T")),
      rule: Model.Rule.ListSort,
      implementation: "List.sort",
      effects: [],
      description: "Stable ascending sort of Int, Float or String; NaN goes last; O(n log n).",
      alternatives: [],
    ),
  ]

ROWS_24: List[Model.Builtin] = [
    Model.Builtin(
      name: "List.sort_by",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A"))),
        Model.Named(name: "key", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Var("K"))),
      ],
      result: Types.Type.List(Types.Type.Var("A")),
      rule: Model.Rule.ListSortBy,
      implementation: "List.sort_by",
      effects: [],
      description: "Stable ascending sort by an Int, Float or String key; one key call per element.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.sum",
      parameters: [Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("N")))],
      result: Types.Type.Var("N"),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Add the Ints or Floats of a list; an empty list gives 0 or 0.0; Int overflow halts; O(n).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.take",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("T"))),
        Model.Named(name: "count", type: Types.Type.Int),
      ],
      result: Types.Type.List(Types.Type.Var("T")),
      rule: Model.Rule.ListCount,
      implementation: "List.take",
      effects: [],
      description: "Take up to count elements; negative counts halt.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.take_while",
      parameters: [
        Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Bool)),
      ],
      result: Types.Type.List(Types.Type.Var("A")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Keep elements while f is true; f stops being called at the first false; O(n).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.tally",
      parameters: [Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("K")))],
      result: Types.Type.Map(Types.Type.Var("K"), Types.Type.Int),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Count equal Int or String elements; keys in order of first appearance; O(n).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "List.uniq",
      parameters: [Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("K")))],
      result: Types.Type.List(Types.Type.Var("K")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Drop repeated Int or String elements, keeping the first of each; O(n).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "LogRegistry.attach",
      parameters: [
        Model.Named(name: "name", type: Types.Type.String),
        Model.Named(name: "rank", type: Types.Type.Int),
        Model.Named(name: "handler", type: Types.Type.Fn([Types.Type.Struct("LogEvent")], Types.Type.Void)),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "LogRegistry.attach",
      effects: ["logging"],
      description: "Internal to std/logger: attach a named handler at a rank; a name in use is an error.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "LogRegistry.detach",
      parameters: [Model.Named(name: "name", type: Types.Type.String)],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "LogRegistry.detach",
      effects: ["logging"],
      description: "Internal to std/logger: detach a named handler; a name not in use is an error.",
      alternatives: [],
    ),
  ]

ROWS_25: List[Model.Builtin] = [
    Model.Builtin(
      name: "LogRegistry.floor",
      parameters: [],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "LogRegistry.floor",
      effects: ["logging"],
      description: (
        "Internal to std/logger: -1 until the default handler is installed, then the higher of the global level's " +
        "rank and the lowest handler rank; a call below it reaches no handler."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "LogRegistry.handlers",
      parameters: [Model.Named(name: "rank", type: Types.Type.Int)],
      result: Types.Type.List(Types.Type.Fn([Types.Type.Struct("LogEvent")], Types.Type.Void)),
      rule: Model.Rule.Plain,
      implementation: "LogRegistry.handlers",
      effects: ["logging"],
      description: "Internal to std/logger: the handlers whose rank is at or below the given rank, in attach order.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "LogRegistry.install_default",
      parameters: [
        Model.Named(name: "handler", type: Types.Type.Fn([Types.Type.Struct("LogEvent")], Types.Type.Void)),
      ],
      result: Types.Type.Void,
      rule: Model.Rule.Plain,
      implementation: "LogRegistry.install_default",
      effects: ["logging"],
      description: (
        "Internal to std/logger: while the level is -1, attach the console handler at info and set the level to " +
        "info, in one step."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "LogRegistry.level",
      parameters: [],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "LogRegistry.level",
      effects: ["logging"],
      description: "Internal to std/logger: the global level's rank, or -1 until the default handler is installed.",
      alternatives: [],
    ),
  ]

ROWS_26: List[Model.Builtin] = [
    Model.Builtin(
      name: "LogRegistry.lowest",
      parameters: [],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "LogRegistry.lowest",
      effects: ["logging"],
      description: "Internal to std/logger: the lowest rank of the attached handlers, or 4 when none is attached.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "LogRegistry.names",
      parameters: [],
      result: Types.Type.List(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "LogRegistry.names",
      effects: ["logging"],
      description: "Internal to std/logger: the names of the attached handlers, in attach order.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "LogRegistry.set_level",
      parameters: [Model.Named(name: "rank", type: Types.Type.Int)],
      result: Types.Type.Void,
      rule: Model.Rule.Plain,
      implementation: "LogRegistry.set_level",
      effects: ["logging"],
      description: "Internal to std/logger: set the global level's rank.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "LogRegistry.task_id",
      parameters: [],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "LogRegistry.task_id",
      effects: ["logging"],
      description: "Internal to std/logger: the running task's number.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Map.delete",
      parameters: [
        Model.Named(name: "map", type: Types.Type.Map(Types.Type.Var("K"), Types.Type.Var("V"))),
        Model.Named(name: "key", type: Types.Type.Var("K")),
      ],
      result: Types.Type.Map(Types.Type.Var("K"), Types.Type.Var("V")),
      rule: Model.Rule.MapDelete,
      implementation: "Map.delete",
      effects: [],
      description: "Return a new map without this key; missing keys leave it unchanged.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Map.each",
      parameters: [
        Model.Named(name: "map", type: Types.Type.Map(Types.Type.Var("K"), Types.Type.Var("V"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("K"), Types.Type.Var("V")], Types.Type.Void)),
      ],
      result: Types.Type.Void,
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Call f(key, value) for each entry in insertion order; returns nothing.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Map.filter",
      parameters: [
        Model.Named(name: "map", type: Types.Type.Map(Types.Type.Var("K"), Types.Type.Var("V"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("K"), Types.Type.Var("V")], Types.Type.Bool)),
      ],
      result: Types.Type.Map(Types.Type.Var("K"), Types.Type.Var("V")),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "Keep the entries f accepts, in insertion order; O(n).",
      alternatives: [],
    ),
  ]

ROWS_27: List[Model.Builtin] = [
    Model.Builtin(
      name: "Map.get",
      parameters: [
        Model.Named(name: "map", type: Types.Type.Map(Types.Type.Var("K"), Types.Type.Var("V"))),
        Model.Named(name: "key", type: Types.Type.Var("K")),
      ],
      result: Types.Type.Result(Types.Type.Var("V")),
      rule: Model.Rule.MapGet,
      implementation: "Map.get",
      effects: [],
      description: "Read a value as a Result, or supply an eagerly evaluated default as a third argument.",
      alternatives: [
        Model.Builtin(
          name: "Map.get",
          parameters: [
            Model.Named(name: "map", type: Types.Type.Map(Types.Type.Var("K"), Types.Type.Var("V"))),
            Model.Named(name: "key", type: Types.Type.Var("K")),
            Model.Named(name: "default", type: Types.Type.Var("V")),
          ],
          result: Types.Type.Var("V"),
          rule: Model.Rule.MapGetDefault,
          implementation: "Map.get",
          effects: [],
          description: "Read a value as a Result, or supply an eagerly evaluated default as a third argument.",
          alternatives: [],
        ),
      ],
    ),
    Model.Builtin(
      name: "Map.has_key?",
      parameters: [
        Model.Named(name: "map", type: Types.Type.Map(Types.Type.Var("K"), Types.Type.Var("V"))),
        Model.Named(name: "key", type: Types.Type.Var("K")),
      ],
      result: Types.Type.Bool,
      rule: Model.Rule.MapHas,
      implementation: "Map.has_key?",
      effects: [],
      description: "Check whether a key exists.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Map.keys",
      parameters: [Model.Named(name: "map", type: Types.Type.Map(Types.Type.Var("K"), Types.Type.Var("V")))],
      result: Types.Type.List(Types.Type.Var("K")),
      rule: Model.Rule.MapKeys,
      implementation: "Map.keys",
      effects: [],
      description: "Return keys in insertion order.",
      alternatives: [],
    ),
  ]

ROWS_28: List[Model.Builtin] = [
    Model.Builtin(
      name: "Map.put",
      parameters: [
        Model.Named(name: "map", type: Types.Type.Map(Types.Type.Var("K"), Types.Type.Var("V"))),
        Model.Named(name: "key", type: Types.Type.Var("K")),
        Model.Named(name: "value", type: Types.Type.Var("V")),
      ],
      result: Types.Type.Map(Types.Type.Var("K"), Types.Type.Var("V")),
      rule: Model.Rule.MapPut,
      implementation: "Map.put",
      effects: [],
      description: "Return a new map with this entry.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Map.size",
      parameters: [Model.Named(name: "map", type: Types.Type.Map(Types.Type.Var("K"), Types.Type.Var("V")))],
      result: Types.Type.Int,
      rule: Model.Rule.MapSize,
      implementation: "Map.size",
      effects: [],
      description: "Count map entries.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Map.values",
      parameters: [Model.Named(name: "map", type: Types.Type.Map(Types.Type.Var("K"), Types.Type.Var("V")))],
      result: Types.Type.List(Types.Type.Var("V")),
      rule: Model.Rule.MapValues,
      implementation: "Map.values",
      effects: [],
      description: "Return values in insertion order.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Path.cwd",
      parameters: [],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "Path.cwd",
      effects: ["filesystem"],
      description: "Return the current working directory.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Path.join",
      parameters: [Model.Named(name: "parts", type: Types.Type.List(Types.Type.String))],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "Path.join",
      effects: ["filesystem"],
      description: "Join path parts using host path semantics.",
      alternatives: [],
    ),
  ]

ROWS_29: List[Model.Builtin] = [
    Model.Builtin(
      name: "Path.real",
      parameters: [Model.Named(name: "path", type: Types.Type.String)],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "Path.real",
      effects: ["filesystem"],
      description: "Return the absolute canonical path with every symbolic link resolved; the path must exist.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Path.remove",
      parameters: [
        Model.Named(name: "path", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "Path.remove",
      effects: ["filesystem"],
      description: (
        "Delete a file, a symbolic link (the link itself) or a directory with everything in it, never following a " +
        "link; a missing path is ok; refuses /, . and ..; VM only."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "Path.rename",
      parameters: [
        Model.Named(name: "from", type: Types.Type.String),
        Model.Named(name: "to", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "Path.rename",
      effects: ["filesystem"],
      description: (
        "Rename a file, a symbolic link (moved as a link) or a directory to a path that does not exist yet, " +
        "atomically (renameat2 with RENAME_NOREPLACE); an existing target is an error, never replaced; VM only."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "Path.resolve",
      parameters: [Model.Named(name: "path", type: Types.Type.String)],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "Path.resolve",
      effects: ["filesystem"],
      description: "Return a lexical absolute path without resolving symlinks.",
      alternatives: [],
    ),
  ]

ROWS_30: List[Model.Builtin] = [
    Model.Builtin(
      name: "Process.channel_close",
      parameters: [
        Model.Named(name: "p", type: Types.Type.Opaque("Process")),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "Process.channel_close",
      effects: ["subprocess"],
      description: "Close the sending side of the channel idempotently; the child reads end of input.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Process.channel_read_line",
      parameters: [
        Model.Named(name: "p", type: Types.Type.Opaque("Process")),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "Process.channel_read_line",
      effects: ["subprocess"],
      description: "Read one line the child wrote on its parent channel; end of input is an error.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Process.channel_send",
      parameters: [
        Model.Named(name: "p", type: Types.Type.Opaque("Process")),
        Model.Named(name: "text", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "Process.channel_send",
      effects: ["subprocess"],
      description: "Send at most 1 MiB of UTF-8 text to the child on the channel.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Process.close",
      parameters: [Model.Named(name: "p", type: Types.Type.Opaque("Process"))],
      result: Types.Type.Void,
      rule: Model.Rule.Plain,
      implementation: "Process.close",
      effects: ["subprocess"],
      description: "Kill and reap the child and close its streams idempotently.",
      alternatives: [],
    ),
  ]

ROWS_31: List[Model.Builtin] = [
    Model.Builtin(
      name: "Process.close_stdin",
      parameters: [
        Model.Named(name: "p", type: Types.Type.Opaque("Process")),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "Process.close_stdin",
      effects: ["subprocess"],
      description: "Close stdin idempotently after flushing.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Process.output",
      parameters: [
        Model.Named(name: "p", type: Types.Type.Opaque("Process")),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Struct("ProcessOutput")),
      rule: Model.Rule.Plain,
      implementation: "Process.output",
      effects: ["subprocess"],
      description: "Wait for both captured streams to end; return unread stdout, all stderr and the truncated mark.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Process.parent_read_line",
      parameters: [Model.Named(name: "timeout_ms", type: Types.Type.Int)],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "Process.parent_read_line",
      effects: ["subprocess"],
      description: "Read one line from the parent channel; an error when the program has no channel.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Process.parent_send",
      parameters: [
        Model.Named(name: "text", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "Process.parent_send",
      effects: ["subprocess"],
      description: (
        "Send at most 1 MiB of UTF-8 text to the parent on the channel; an error when the program has no channel."
      ),
      alternatives: [],
    ),
  ]

ROWS_32: List[Model.Builtin] = [
    Model.Builtin(
      name: "Process.read_available",
      parameters: [
        Model.Named(name: "p", type: Types.Type.Opaque("Process")),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "Process.read_available",
      effects: ["subprocess"],
      description: (
        "Read the captured stdout written so far without waiting for more; timeout_ms bounds only the wait for the " +
        "reader lock."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "Process.read_bytes",
      parameters: [
        Model.Named(name: "p", type: Types.Type.Opaque("Process")),
        Model.Named(name: "count", type: Types.Type.Int),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.List(Types.Type.Int)),
      rule: Model.Rule.Plain,
      implementation: "Process.read_bytes",
      effects: ["subprocess"],
      description: "Read count bytes or fewer at EOF; count is 0..1048576.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Process.read_line",
      parameters: [
        Model.Named(name: "p", type: Types.Type.Opaque("Process")),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "Process.read_line",
      effects: ["subprocess"],
      description: "Read a bounded UTF-8 line; empty EOF is an error.",
      alternatives: [],
    ),
  ]

ROWS_33: List[Model.Builtin] = [
    Model.Builtin(
      name: "Process.send",
      parameters: [
        Model.Named(name: "p", type: Types.Type.Opaque("Process")),
        Model.Named(name: "text", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "Process.send",
      effects: ["subprocess"],
      description: "Send at most 1 MiB of UTF-8 text and flush.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Process.send_bytes",
      parameters: [
        Model.Named(name: "p", type: Types.Type.Opaque("Process")),
        Model.Named(name: "bytes", type: Types.Type.List(Types.Type.Int)),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "Process.send_bytes",
      effects: ["subprocess"],
      description: "Send at most 1 MiB of bytes 0..255 and flush.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Process.spawn",
      parameters: [
        Model.Named(name: "command", type: Types.Type.String),
        Model.Named(name: "args", type: Types.Type.List(Types.Type.String)),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Opaque("Process")),
      rule: Model.Rule.Plain,
      implementation: "Process.spawn",
      effects: ["subprocess"],
      description: "Start an executable with literal arguments; requires --allow-run.",
      alternatives: [],
    ),
  ]

ROWS_34: List[Model.Builtin] = [
    Model.Builtin(
      name: "Process.spawn_captured",
      parameters: [
        Model.Named(name: "command", type: Types.Type.String),
        Model.Named(name: "args", type: Types.Type.List(Types.Type.String)),
        Model.Named(name: "dir", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Opaque("Process")),
      rule: Model.Rule.Plain,
      implementation: "Process.spawn_captured",
      effects: ["subprocess"],
      description: "Start an executable in dir with stdout and stderr kept in 1 MiB buffers; VM only.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Process.spawn_channel",
      parameters: [
        Model.Named(name: "command", type: Types.Type.String),
        Model.Named(name: "args", type: Types.Type.List(Types.Type.String)),
        Model.Named(name: "dir", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Opaque("Process")),
      rule: Model.Rule.Plain,
      implementation: "Process.spawn_channel",
      effects: ["subprocess"],
      description: (
        "Like spawn_captured, plus a channel to the child: fd 3 and AGENTICA_CHANNEL=3 in the child; VM only."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "Process.wait",
      parameters: [
        Model.Named(name: "p", type: Types.Type.Opaque("Process")),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Int),
      rule: Model.Rule.Plain,
      implementation: "Process.wait",
      effects: ["subprocess"],
      description: "Wait for exit and stderr forwarding; timeout preserves the child.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Profile.measure",
      parameters: [
        Model.Named(name: "label", type: Types.Type.String),
        Model.Named(name: "block", type: Types.Type.Fn([], Types.Type.Var("T"))),
      ],
      result: Types.Type.Var("T"),
      rule: Model.Rule.ProfileMeasure,
      implementation: "Profile.measure",
      effects: [],
      description: (
        "Run the block and return its value; with AGENTICA_VM_TRACE=profile, its calls, steps, time and GC time " +
        "go to a section row of the profile under label; VM only."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "Profile.steps",
      parameters: [],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "Profile.steps",
      effects: [],
      description: "Count the steps this task has run so far; the same on every run, with or without the profile.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Random.float",
      parameters: [],
      result: Types.Type.Float,
      rule: Model.Rule.Plain,
      implementation: "Random.float",
      effects: ["random"],
      description: "Pick a uniform Float in 0.0 up to, but not including, 1.0.",
      alternatives: [],
    ),
  ]

ROWS_35: List[Model.Builtin] = [
    Model.Builtin(
      name: "Random.int",
      parameters: [Model.Named(name: "min", type: Types.Type.Int), Model.Named(name: "max", type: Types.Type.Int)],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "Random.int",
      effects: ["random"],
      description: "Pick a uniform Int in min..max inclusive; min > max halts.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Range.each",
      parameters: [
        Model.Named(name: "range", type: Types.Type.Range),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Int], Types.Type.Void)),
      ],
      result: Types.Type.Void,
      rule: Model.Rule.Plain,
      implementation: "Range.each",
      effects: [],
      description: "Call f on each value in order; returns nothing.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Range.first",
      parameters: [Model.Named(name: "range", type: Types.Type.Range)],
      result: Types.Type.Result(Types.Type.Int),
      rule: Model.Rule.Plain,
      implementation: "Range.first",
      effects: [],
      description: "The first value; an error for an empty range.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Range.include?",
      parameters: [
        Model.Named(name: "range", type: Types.Type.Range),
        Model.Named(name: "value", type: Types.Type.Int),
      ],
      result: Types.Type.Bool,
      rule: Model.Rule.Plain,
      implementation: "Range.include?",
      effects: [],
      description: "Check whether a value is in the range.",
      alternatives: [],
    ),
  ]

ROWS_36: List[Model.Builtin] = [
    Model.Builtin(
      name: "Range.lazy",
      parameters: [Model.Named(name: "range", type: Types.Type.Range)],
      result: Types.Type.Lazy(Types.Type.Int),
      rule: Model.Rule.Prelude,
      implementation: "",
      effects: [],
      description: "A Lazy over the range: steps run only in a terminal, one item at a time.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Range.last",
      parameters: [Model.Named(name: "range", type: Types.Type.Range)],
      result: Types.Type.Result(Types.Type.Int),
      rule: Model.Rule.Plain,
      implementation: "Range.last",
      effects: [],
      description: "The last included value; an error for an empty range.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Range.size",
      parameters: [Model.Named(name: "range", type: Types.Type.Range)],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "Range.size",
      effects: [],
      description: "Count the values; halts when the count does not fit in Int.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Range.to_a",
      parameters: [Model.Named(name: "range", type: Types.Type.Range)],
      result: Types.Type.List(Types.Type.Int),
      rule: Model.Rule.Plain,
      implementation: "Range.to_a",
      effects: [],
      description: "List the values in order; at most 1048576 values.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Result.message",
      parameters: [Model.Named(name: "r", type: Types.Type.Result(Types.Type.Var("T")))],
      result: Types.Type.String,
      rule: Model.Rule.ResultMessage,
      implementation: "Result.message",
      effects: [],
      description: "Return an error message, or empty text for success.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Result.ok?",
      parameters: [Model.Named(name: "r", type: Types.Type.Result(Types.Type.Var("T")))],
      result: Types.Type.Bool,
      rule: Model.Rule.ResultOk,
      implementation: "Result.ok?",
      effects: [],
      description: "Check whether a Result succeeded.",
      alternatives: [],
    ),
  ]

ROWS_37: List[Model.Builtin] = [
    Model.Builtin(
      name: "Result.unwrap!",
      parameters: [Model.Named(name: "r", type: Types.Type.Result(Types.Type.Var("T")))],
      result: Types.Type.Var("T"),
      rule: Model.Rule.ResultUnwrap,
      implementation: "Result.unwrap!",
      effects: [],
      description: "Return the success value; halt on error.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Result.unwrap_or",
      parameters: [
        Model.Named(name: "r", type: Types.Type.Result(Types.Type.Var("T"))),
        Model.Named(name: "default", type: Types.Type.Var("T")),
      ],
      result: Types.Type.Var("T"),
      rule: Model.Rule.ResultDefault,
      implementation: "Result.unwrap_or",
      effects: [],
      description: "Return success or default; both arguments run eagerly.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Set.add",
      parameters: [
        Model.Named(name: "set", type: Types.Type.Set(Types.Type.Var("T"))),
        Model.Named(name: "value", type: Types.Type.Var("T")),
      ],
      result: Types.Type.Set(Types.Type.Var("T")),
      rule: Model.Rule.SetAdd,
      implementation: "Set.add",
      effects: [],
      description: "Return a new set with this element; a member leaves the set unchanged.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Set.delete",
      parameters: [
        Model.Named(name: "set", type: Types.Type.Set(Types.Type.Var("T"))),
        Model.Named(name: "value", type: Types.Type.Var("T")),
      ],
      result: Types.Type.Set(Types.Type.Var("T")),
      rule: Model.Rule.SetAdd,
      implementation: "Set.delete",
      effects: [],
      description: "Return a new set without this element; a missing element leaves it unchanged.",
      alternatives: [],
    ),
  ]

ROWS_38: List[Model.Builtin] = [
    Model.Builtin(
      name: "Set.difference",
      parameters: [
        Model.Named(name: "a", type: Types.Type.Set(Types.Type.Var("T"))),
        Model.Named(name: "b", type: Types.Type.Set(Types.Type.Var("T"))),
      ],
      result: Types.Type.Set(Types.Type.Var("T")),
      rule: Model.Rule.SetCombine,
      implementation: "Set.difference",
      effects: [],
      description: "Return the elements of a that are not in b, in the order of a.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Set.empty?",
      parameters: [Model.Named(name: "set", type: Types.Type.Set(Types.Type.Var("T")))],
      result: Types.Type.Bool,
      rule: Model.Rule.SetQuery,
      implementation: "Set.empty?",
      effects: [],
      description: "Check whether the set has no elements.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Set.include?",
      parameters: [
        Model.Named(name: "set", type: Types.Type.Set(Types.Type.Var("T"))),
        Model.Named(name: "value", type: Types.Type.Var("T")),
      ],
      result: Types.Type.Bool,
      rule: Model.Rule.SetInclude,
      implementation: "Set.include?",
      effects: [],
      description: "Check whether an element is in the set.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Set.intersection",
      parameters: [
        Model.Named(name: "a", type: Types.Type.Set(Types.Type.Var("T"))),
        Model.Named(name: "b", type: Types.Type.Set(Types.Type.Var("T"))),
      ],
      result: Types.Type.Set(Types.Type.Var("T")),
      rule: Model.Rule.SetCombine,
      implementation: "Set.intersection",
      effects: [],
      description: "Return the elements of a that are also in b, in the order of a.",
      alternatives: [],
    ),
  ]

ROWS_39: List[Model.Builtin] = [
    Model.Builtin(
      name: "Set.new",
      parameters: [Model.Named(name: "items", type: Types.Type.List(Types.Type.Var("T")))],
      result: Types.Type.Set(Types.Type.Var("T")),
      rule: Model.Rule.SetNew,
      implementation: "Set.new",
      effects: [],
      description: (
        "Build a set from a list of Int or String; duplicates are dropped and the first one keeps its place. An " +
        "empty list needs an expected type."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "Set.size",
      parameters: [Model.Named(name: "set", type: Types.Type.Set(Types.Type.Var("T")))],
      result: Types.Type.Int,
      rule: Model.Rule.SetQuery,
      implementation: "Set.size",
      effects: [],
      description: "Count set elements.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Set.subset?",
      parameters: [
        Model.Named(name: "a", type: Types.Type.Set(Types.Type.Var("T"))),
        Model.Named(name: "b", type: Types.Type.Set(Types.Type.Var("T"))),
      ],
      result: Types.Type.Bool,
      rule: Model.Rule.SetSubset,
      implementation: "Set.subset?",
      effects: [],
      description: "Check whether every element of a is in b.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Set.to_a",
      parameters: [Model.Named(name: "set", type: Types.Type.Set(Types.Type.Var("T")))],
      result: Types.Type.List(Types.Type.Var("T")),
      rule: Model.Rule.SetToA,
      implementation: "Set.to_a",
      effects: [],
      description: "Return the elements in first-insertion order.",
      alternatives: [],
    ),
  ]

ROWS_40: List[Model.Builtin] = [
    Model.Builtin(
      name: "Set.union",
      parameters: [
        Model.Named(name: "a", type: Types.Type.Set(Types.Type.Var("T"))),
        Model.Named(name: "b", type: Types.Type.Set(Types.Type.Var("T"))),
      ],
      result: Types.Type.Set(Types.Type.Var("T")),
      rule: Model.Rule.SetCombine,
      implementation: "Set.union",
      effects: [],
      description: "Return the elements of a, then the elements of b that a lacks.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.at",
      parameters: [Model.Named(name: "s", type: Types.Type.String), Model.Named(name: "index", type: Types.Type.Int)],
      result: Types.Type.String,
      rule: Model.Rule.Plain,
      implementation: "String.at",
      effects: [],
      description: "Read one character at a zero-based index; invalid indexes halt.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.code",
      parameters: [Model.Named(name: "c", type: Types.Type.String)],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "String.code",
      effects: [],
      description: "Return the code point of a one-character string; other lengths halt.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.compare",
      parameters: [
        Model.Named(name: "a", type: Types.Type.String),
        Model.Named(name: "b", type: Types.Type.String),
      ],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "String.compare",
      effects: [],
      description: "Compare two Strings in the order of sort: -1, 0 or 1.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.contains?",
      parameters: [
        Model.Named(name: "s", type: Types.Type.String),
        Model.Named(name: "part", type: Types.Type.String),
      ],
      result: Types.Type.Bool,
      rule: Model.Rule.Plain,
      implementation: "String.contains?",
      effects: [],
      description: "Check for a substring.",
      alternatives: [],
    ),
  ]

ROWS_41: List[Model.Builtin] = [
    Model.Builtin(
      name: "String.downcase",
      parameters: [Model.Named(name: "s", type: Types.Type.String)],
      result: Types.Type.String,
      rule: Model.Rule.Plain,
      implementation: "String.downcase",
      effects: [],
      description: "Lowercase text.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.ends_with?",
      parameters: [
        Model.Named(name: "s", type: Types.Type.String),
        Model.Named(name: "suffix", type: Types.Type.String),
      ],
      result: Types.Type.Bool,
      rule: Model.Rule.Plain,
      implementation: "String.ends_with?",
      effects: [],
      description: "Check a suffix.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.from_bytes",
      parameters: [Model.Named(name: "data", type: Types.Type.List(Types.Type.Int))],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "String.from_bytes",
      effects: [],
      description: "Decode UTF-8 strictly; invalid bytes or incomplete sequences return an error.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.from_code",
      parameters: [Model.Named(name: "n", type: Types.Type.Int)],
      result: Types.Type.String,
      rule: Model.Rule.Plain,
      implementation: "String.from_code",
      effects: [],
      description: "Build a one-character string from a Unicode scalar value; invalid values halt.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.from_float",
      parameters: [Model.Named(name: "x", type: Types.Type.Float)],
      result: Types.Type.String,
      rule: Model.Rule.Plain,
      implementation: "String.from_float",
      effects: [],
      description: "Format a float.",
      alternatives: [],
    ),
  ]

ROWS_42: List[Model.Builtin] = [
    Model.Builtin(
      name: "String.from_int",
      parameters: [Model.Named(name: "n", type: Types.Type.Int)],
      result: Types.Type.String,
      rule: Model.Rule.Plain,
      implementation: "String.from_int",
      effects: [],
      description: "Format an integer.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.index_of",
      parameters: [
        Model.Named(name: "s", type: Types.Type.String),
        Model.Named(name: "part", type: Types.Type.String),
      ],
      result: Types.Type.Result(Types.Type.Int),
      rule: Model.Rule.Plain,
      implementation: "String.index_of",
      effects: [],
      description: "Find the first character index of part; absent text returns an error.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.join",
      parameters: [
        Model.Named(name: "parts", type: Types.Type.List(Types.Type.String)),
        Model.Named(name: "separator", type: Types.Type.String),
      ],
      result: Types.Type.String,
      rule: Model.Rule.Plain,
      implementation: "String.join",
      effects: [],
      description: "Join text elements.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.length",
      parameters: [Model.Named(name: "s", type: Types.Type.String)],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "String.length",
      effects: [],
      description: "Count Unicode characters.",
      alternatives: [],
    ),
  ]

ROWS_43: List[Model.Builtin] = [
    Model.Builtin(
      name: "String.replace",
      parameters: [
        Model.Named(name: "s", type: Types.Type.String),
        Model.Named(name: "from", type: Types.Type.String),
        Model.Named(name: "to", type: Types.Type.String),
      ],
      result: Types.Type.String,
      rule: Model.Rule.Plain,
      implementation: "String.replace",
      effects: [],
      description: "Replace occurrences of text.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.reverse",
      parameters: [Model.Named(name: "s", type: Types.Type.String)],
      result: Types.Type.String,
      rule: Model.Rule.Plain,
      implementation: "String.reverse",
      effects: [],
      description: "Reverse the Unicode characters.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.slice",
      parameters: [
        Model.Named(name: "s", type: Types.Type.String),
        Model.Named(name: "start", type: Types.Type.Int),
        Model.Named(name: "length", type: Types.Type.Int),
      ],
      result: Types.Type.String,
      rule: Model.Rule.Plain,
      implementation: "String.slice",
      effects: [],
      description: "Read a character range; halt outside bounds.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.split",
      parameters: [
        Model.Named(name: "s", type: Types.Type.String),
        Model.Named(name: "separator", type: Types.Type.String),
      ],
      result: Types.Type.List(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "String.split",
      effects: [],
      description: "Split text; an empty separator gives characters.",
      alternatives: [],
    ),
  ]

ROWS_44: List[Model.Builtin] = [
    Model.Builtin(
      name: "String.starts_with?",
      parameters: [
        Model.Named(name: "s", type: Types.Type.String),
        Model.Named(name: "prefix", type: Types.Type.String),
      ],
      result: Types.Type.Bool,
      rule: Model.Rule.Plain,
      implementation: "String.starts_with?",
      effects: [],
      description: "Check a prefix.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.to_bytes",
      parameters: [Model.Named(name: "s", type: Types.Type.String)],
      result: Types.Type.List(Types.Type.Int),
      rule: Model.Rule.Plain,
      implementation: "String.to_bytes",
      effects: [],
      description: "Encode a string as its UTF-8 bytes; the inverse of String.from_bytes.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.to_float",
      parameters: [Model.Named(name: "s", type: Types.Type.String)],
      result: Types.Type.Result(Types.Type.Float),
      rule: Model.Rule.Plain,
      implementation: "String.to_float",
      effects: [],
      description: "Parse signed decimal Float as a Result.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.to_float!",
      parameters: [Model.Named(name: "s", type: Types.Type.String)],
      result: Types.Type.Float,
      rule: Model.Rule.Plain,
      implementation: "String.to_float!",
      effects: [],
      description: "Parse signed decimal Float; halt on invalid text.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.to_int",
      parameters: [Model.Named(name: "s", type: Types.Type.String)],
      result: Types.Type.Result(Types.Type.Int),
      rule: Model.Rule.Plain,
      implementation: "String.to_int",
      effects: [],
      description: "Parse signed decimal Int as a Result.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.to_int!",
      parameters: [Model.Named(name: "s", type: Types.Type.String)],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "String.to_int!",
      effects: [],
      description: "Parse signed decimal Int; halt on invalid text or overflow.",
      alternatives: [],
    ),
  ]

ROWS_45: List[Model.Builtin] = [
    Model.Builtin(
      name: "String.trim",
      parameters: [Model.Named(name: "s", type: Types.Type.String)],
      result: Types.Type.String,
      rule: Model.Rule.Plain,
      implementation: "String.trim",
      effects: [],
      description: "Trim surrounding whitespace.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "String.upcase",
      parameters: [Model.Named(name: "s", type: Types.Type.String)],
      result: Types.Type.String,
      rule: Model.Rule.Plain,
      implementation: "String.upcase",
      effects: [],
      description: "Uppercase text.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "System.args",
      parameters: [],
      result: Types.Type.List(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "System.args",
      effects: ["process"],
      description: "Return program arguments.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "System.env",
      parameters: [Model.Named(name: "name", type: Types.Type.String)],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "System.env",
      effects: ["process"],
      description: (
        "Read an environment variable; an unset variable or an invalid name returns an error, and an empty value " +
        "returns ok."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "System.exit",
      parameters: [Model.Named(name: "code", type: Types.Type.Int)],
      result: Types.Type.Void,
      rule: Model.Rule.Plain,
      implementation: "System.exit",
      effects: ["process"],
      description: "End the run with an exit code.",
      alternatives: [],
    ),
  ]

ROWS_46: List[Model.Builtin] = [
    Model.Builtin(
      name: "System.os",
      parameters: [],
      result: Types.Type.String,
      rule: Model.Rule.Plain,
      implementation: "System.os",
      effects: ["process"],
      description: (
        "Return the operating system: linux, macos, windows, or the lowercase name uname gives on another system; " +
        "VM only."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "System.pid",
      parameters: [],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "System.pid",
      effects: ["process"],
      description: "Return the process id of this program; VM only.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "TCP.accept",
      parameters: [
        Model.Named(name: "listener", type: Types.Type.Opaque("Listener")),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Opaque("Socket")),
      rule: Model.Rule.Plain,
      implementation: "TCP.accept",
      effects: ["network"],
      description: "Accept a TCP or TLS connection.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "TCP.close",
      parameters: [Model.Named(name: "socket", type: Types.Type.Opaque("Socket"))],
      result: Types.Type.Void,
      rule: Model.Rule.Plain,
      implementation: "TCP.close",
      effects: ["network"],
      description: "Close a socket idempotently.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "TCP.close_listener",
      parameters: [Model.Named(name: "listener", type: Types.Type.Opaque("Listener"))],
      result: Types.Type.Void,
      rule: Model.Rule.Plain,
      implementation: "TCP.close_listener",
      effects: ["network"],
      description: "Close a listener idempotently.",
      alternatives: [],
    ),
  ]

ROWS_47: List[Model.Builtin] = [
    Model.Builtin(
      name: "TCP.connect",
      parameters: [
        Model.Named(name: "host", type: Types.Type.String),
        Model.Named(name: "port", type: Types.Type.Int),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Opaque("Socket")),
      rule: Model.Rule.Plain,
      implementation: "TCP.connect",
      effects: ["network"],
      description: "Connect to a TCP peer within a deadline.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "TCP.listen",
      parameters: [
        Model.Named(name: "host", type: Types.Type.String),
        Model.Named(name: "port", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Opaque("Listener")),
      rule: Model.Rule.Plain,
      implementation: "TCP.listen",
      effects: ["network"],
      description: "Listen on an address; port zero chooses a free port.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "TCP.local_port",
      parameters: [Model.Named(name: "listener", type: Types.Type.Opaque("Listener"))],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "TCP.local_port",
      effects: ["network"],
      description: "Return the actual listening port.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "TCP.read_line",
      parameters: [
        Model.Named(name: "socket", type: Types.Type.Opaque("Socket")),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "TCP.read_line",
      effects: ["network"],
      description: "Read a bounded UTF-8 line, removing its terminator.",
      alternatives: [],
    ),
  ]

ROWS_48: List[Model.Builtin] = [
    Model.Builtin(
      name: "TCP.recv_bytes",
      parameters: [
        Model.Named(name: "socket", type: Types.Type.Opaque("Socket")),
        Model.Named(name: "max_bytes", type: Types.Type.Int),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.List(Types.Type.Int)),
      rule: Model.Rule.Plain,
      implementation: "TCP.recv_bytes",
      effects: ["network"],
      description: "Read available bytes; an empty list indicates EOF.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "TCP.send",
      parameters: [
        Model.Named(name: "socket", type: Types.Type.Opaque("Socket")),
        Model.Named(name: "text", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "TCP.send",
      effects: ["network"],
      description: "Send UTF-8 text and flush.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "TCP.send_bytes",
      parameters: [
        Model.Named(name: "socket", type: Types.Type.Opaque("Socket")),
        Model.Named(name: "bytes", type: Types.Type.List(Types.Type.Int)),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "TCP.send_bytes",
      effects: ["network"],
      description: "Send bytes 0..255 and flush, at most 1 MiB per call.",
      alternatives: [],
    ),
  ]

ROWS_49: List[Model.Builtin] = [
    Model.Builtin(
      name: "TLS.connect",
      parameters: [
        Model.Named(name: "host", type: Types.Type.String),
        Model.Named(name: "port", type: Types.Type.Int),
        Model.Named(name: "ca_file", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Opaque("Socket")),
      rule: Model.Rule.Plain,
      implementation: "TLS.connect",
      effects: ["network"],
      description: "Connect with certificate and hostname verification; empty CA uses system trust.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "TLS.listen",
      parameters: [
        Model.Named(name: "host", type: Types.Type.String),
        Model.Named(name: "port", type: Types.Type.Int),
        Model.Named(name: "cert_file", type: Types.Type.String),
        Model.Named(name: "key_file", type: Types.Type.String),
      ],
      result: Types.Type.Result(Types.Type.Opaque("Listener")),
      rule: Model.Rule.Plain,
      implementation: "TLS.listen",
      effects: ["network"],
      description: "Listen with a PEM certificate chain and private key.",
      alternatives: [],
    ),
  ]

ROWS_50: List[Model.Builtin] = [
    Model.Builtin(
      name: "Task.await",
      parameters: [Model.Named(name: "task", type: Types.Type.Task(Types.Type.Var("R")))],
      result: Types.Type.Var("R"),
      rule: Model.Rule.TaskAwait,
      implementation: "Task.await",
      effects: ["concurrency"],
      description: (
        "Wait for a task and return its cached result; a crashed task gives error(text) when R is a Result, else " +
        "RUNTIME-TASK-CRASHED."
      ),
      alternatives: [
        Model.Builtin(
          name: "Task.await",
          parameters: [
            Model.Named(name: "task", type: Types.Type.Task(Types.Type.Var("R"))),
            Model.Named(name: "timeout_ms", type: Types.Type.Int),
          ],
          result: Types.Type.Enum("Await", [Types.Type.Var("R")]),
          rule: Model.Rule.TaskAwaitTimeout,
          implementation: "Task.await",
          effects: ["concurrency"],
          description: (
            "Wait for a task for at most timeout_ms; Await.Done(value) with its cached result, or Await.TimedOut, " +
            "and the task keeps running; timeout_ms must be positive."
          ),
          alternatives: [],
        ),
      ],
    ),
    Model.Builtin(
      name: "Task.cancel",
      parameters: [Model.Named(name: "task", type: Types.Type.Task(Types.Type.Var("R")))],
      result: Types.Type.Void,
      rule: Model.Rule.TaskTarget,
      implementation: "Task.cancel",
      effects: ["concurrency"],
      description: (
        "Cancel a task and its descendants without waiting: each runs at most the rest of its current turn and " +
        "closes what it owns; does nothing for a task that has ended; VM only."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "Task.map",
      parameters: [
        Model.Named(name: "items", type: Types.Type.List(Types.Type.Var("A"))),
        Model.Named(name: "limit", type: Types.Type.Int),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Result(Types.Type.Var("R")))),
      ],
      result: Types.Type.List(Types.Type.Result(Types.Type.Var("R"))),
      rule: Model.Rule.TaskMap,
      implementation: "Task.map",
      effects: ["concurrency"],
      description: (
        "Run the block for each item in its own task, at most limit (1 to 1024) at a time, each with its own " +
        "timeout_ms (positive, from the start of that item); gives one Result per item in input order, an error " +
        "(task: timed out) for an item that ran out of time, which is cancelled; VM only."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "Task.pending_count",
      parameters: [],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "Task.pending_count",
      effects: ["concurrency"],
      description: "Count the tasks of this run that have not ended, not counting main; VM only.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Task.sleep",
      parameters: [Model.Named(name: "milliseconds", type: Types.Type.Int)],
      result: Types.Type.Void,
      rule: Model.Rule.Plain,
      implementation: "Task.sleep",
      effects: ["concurrency"],
      description: "Suspend this task for nonnegative milliseconds; zero yields execution.",
      alternatives: [],
    ),
  ]

ROWS_51: List[Model.Builtin] = [
    Model.Builtin(
      name: "Task.spawn",
      parameters: [
        Model.Named(name: "function", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Var("R"))),
        Model.Named(name: "argument", type: Types.Type.Var("A")),
      ],
      result: Types.Type.Task(Types.Type.Var("R")),
      rule: Model.Rule.TaskSpawn,
      implementation: "Task.spawn",
      effects: ["concurrency"],
      description: "Start a named function with one argument in a lightweight task.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Task.spawn_owning",
      parameters: [
        Model.Named(name: "function", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Var("R"))),
        Model.Named(name: "handle", type: Types.Type.Var("A")),
      ],
      result: Types.Type.Task(Types.Type.Var("R")),
      rule: Model.Rule.TaskSpawnOwning,
      implementation: "Task.spawn_owning",
      effects: ["concurrency"],
      description: (
        "Like Task.spawn, and gives the handle or Channel argument, which the calling task must own (an unowned " +
        "Channel counts), to the new task; VM only."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "Task.unobserved_crash",
      parameters: [],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "Task.unobserved_crash",
      effects: ["concurrency"],
      description: "Return the text of the first task crash no await has observed, or an error.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Test.assert",
      parameters: [
        Model.Named(name: "condition", type: Types.Type.Bool),
        Model.Named(name: "message", type: Types.Type.String),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "Test.assert",
      effects: ["test"],
      description: "Check a condition; a failure with message is recorded on the test.",
      alternatives: [],
    ),
  ]

ROWS_52: List[Model.Builtin] = [
    Model.Builtin(
      name: "Test.eq",
      parameters: [
        Model.Named(name: "actual", type: Types.Type.Var("T")),
        Model.Named(name: "expected", type: Types.Type.Var("T")),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.TestEq,
      implementation: "Test.eq",
      effects: ["test"],
      description: (
        "Compare two values of a type with equality (Json as canonical text); a failure is recorded on the test."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "Test.error?",
      parameters: [Model.Named(name: "result", type: Types.Type.Result(Types.Type.Var("T")))],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.TestResult,
      implementation: "Test.error?",
      effects: ["test"],
      description: "Check that a Result is an error; a failure is recorded on the test.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Test.ok?",
      parameters: [Model.Named(name: "result", type: Types.Type.Result(Types.Type.Var("T")))],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.TestResult,
      implementation: "Test.ok?",
      effects: ["test"],
      description: "Check that a Result is ok; a failure is recorded on the test.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Test.run",
      parameters: [Model.Named(name: "tests", type: Types.Type.List(Types.Type.Opaque("TestCase")))],
      result: Types.Type.Void,
      rule: Model.Rule.Plain,
      implementation: "Test.run",
      effects: ["process", "concurrency"],
      description: "Serve agentica test: list the tests or run each in its own task; never returns.",
      alternatives: [],
    ),
  ]

ROWS_53: List[Model.Builtin] = [
    Model.Builtin(
      name: "Test.test",
      parameters: [
        Model.Named(name: "name", type: Types.Type.String),
        Model.Named(name: "body", type: Types.Type.Fn([], Types.Type.Result(Types.Type.Void))),
      ],
      result: Types.Type.Opaque("TestCase"),
      rule: Model.Rule.Plain,
      implementation: "Test.test",
      effects: [],
      description: "Build a test case from a name and a block that returns Result[Void]; Test.run runs it.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Time.monotonic_ms",
      parameters: [],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "Time.monotonic_ms",
      effects: ["clock"],
      description: "Read milliseconds from an arbitrary origin that never goes backward; use for durations.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Time.monotonic_ns",
      parameters: [],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "Time.monotonic_ns",
      effects: ["clock"],
      description: (
        "Read nanoseconds from the clock of Time.monotonic_ms; same origin, never goes backward; use for short " +
        "durations."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "Time.now_ms",
      parameters: [],
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "Time.now_ms",
      effects: ["clock"],
      description: "Read wall-clock milliseconds since the Unix epoch; may jump.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "__fail_arg",
      parameters: [
        Model.Named(name: "code", type: Types.Type.String),
        Model.Named(name: "index", type: Types.Type.Int),
        Model.Named(name: "message", type: Types.Type.String),
      ],
      result: Types.Type.Void,
      rule: Model.Rule.Plain,
      implementation: "__fail_arg",
      effects: [],
      description: "Internal to the prelude: halt with a RUNTIME- code at the argument of the call of the program.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "__lazy_channel",
      parameters: [
        Model.Named(name: "channel", type: Types.Type.Channel(Types.Type.Var("A"))),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Lazy(Types.Type.Var("A")),
      rule: Model.Rule.Plain,
      implementation: "__lazy_channel",
      effects: [],
      description: "Internal to the prelude: a step or terminal of Lazy (vm/lazy.c).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "__lazy_chunk_while",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A"), Types.Type.Var("A")], Types.Type.Bool)),
      ],
      result: Types.Type.Lazy(Types.Type.List(Types.Type.Var("A"))),
      rule: Model.Rule.Plain,
      implementation: "__lazy_chunk_while",
      effects: [],
      description: "Internal to the prelude: a step or terminal of Lazy (vm/lazy.c).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "__lazy_count",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "kind", type: Types.Type.Int),
        Model.Named(name: "count", type: Types.Type.Int),
      ],
      result: Types.Type.Lazy(Types.Type.Var("A")),
      rule: Model.Rule.Plain,
      implementation: "__lazy_count",
      effects: [],
      description: "Internal to the prelude: a step or terminal of Lazy (vm/lazy.c).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "__lazy_each",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Result(Types.Type.Void))),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "__lazy_each",
      effects: [],
      description: "Internal to the prelude: a step or terminal of Lazy (vm/lazy.c).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "__lazy_file",
      parameters: [
        Model.Named(name: "path", type: Types.Type.String),
        Model.Named(name: "buffer_bytes", type: Types.Type.Int),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Lazy(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "__lazy_file",
      effects: [],
      description: "Internal to the prelude: a step or terminal of Lazy (vm/lazy.c).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "__lazy_find",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Bool)),
      ],
      result: Types.Type.Result(Types.Type.Var("A")),
      rule: Model.Rule.Plain,
      implementation: "__lazy_find",
      effects: [],
      description: "Internal to the prelude: a step or terminal of Lazy (vm/lazy.c).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "__lazy_flat_map",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.List(Types.Type.Var("B")))),
      ],
      result: Types.Type.Lazy(Types.Type.Var("B")),
      rule: Model.Rule.Plain,
      implementation: "__lazy_flat_map",
      effects: [],
      description: "Internal to the prelude: a step or terminal of Lazy (vm/lazy.c).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "__lazy_group",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "kind", type: Types.Type.Int),
        Model.Named(name: "size", type: Types.Type.Int),
      ],
      result: Types.Type.Lazy(Types.Type.List(Types.Type.Var("A"))),
      rule: Model.Rule.Plain,
      implementation: "__lazy_group",
      effects: [],
      description: "Internal to the prelude: a step or terminal of Lazy (vm/lazy.c).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "__lazy_list",
      parameters: [Model.Named(name: "list", type: Types.Type.List(Types.Type.Var("A")))],
      result: Types.Type.Lazy(Types.Type.Var("A")),
      rule: Model.Rule.Plain,
      implementation: "__lazy_list",
      effects: [],
      description: "Internal to the prelude: a step or terminal of Lazy (vm/lazy.c).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "__lazy_map",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Var("B"))),
      ],
      result: Types.Type.Lazy(Types.Type.Var("B")),
      rule: Model.Rule.Plain,
      implementation: "__lazy_map",
      effects: [],
      description: "Internal to the prelude: a step or terminal of Lazy (vm/lazy.c).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "__lazy_produce",
      parameters: [
        Model.Named(name: "seed", type: Types.Type.Var("A")),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Var("A"))),
      ],
      result: Types.Type.Lazy(Types.Type.Var("A")),
      rule: Model.Rule.Plain,
      implementation: "__lazy_produce",
      effects: [],
      description: "Internal to the prelude: a step or terminal of Lazy (vm/lazy.c).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "__lazy_range",
      parameters: [Model.Named(name: "range", type: Types.Type.Range)],
      result: Types.Type.Lazy(Types.Type.Int),
      rule: Model.Rule.Plain,
      implementation: "__lazy_range",
      effects: [],
      description: "Internal to the prelude: a step or terminal of Lazy (vm/lazy.c).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "__lazy_reduce",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "initial", type: Types.Type.Var("B")),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("B"), Types.Type.Var("A")], Types.Type.Var("B"))),
      ],
      result: Types.Type.Result(Types.Type.Var("B")),
      rule: Model.Rule.Plain,
      implementation: "__lazy_reduce",
      effects: [],
      description: "Internal to the prelude: a step or terminal of Lazy (vm/lazy.c).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "__lazy_test",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "kind", type: Types.Type.Int),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Bool)),
      ],
      result: Types.Type.Lazy(Types.Type.Var("A")),
      rule: Model.Rule.Plain,
      implementation: "__lazy_test",
      effects: [],
      description: "Internal to the prelude: a step or terminal of Lazy (vm/lazy.c).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "__lazy_to_a",
      parameters: [Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A")))],
      result: Types.Type.Result(Types.Type.List(Types.Type.Var("A"))),
      rule: Model.Rule.Plain,
      implementation: "__lazy_to_a",
      effects: [],
      description: "Internal to the prelude: a step or terminal of Lazy (vm/lazy.c).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "__lazy_with_index",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
        Model.Named(name: "f", type: Types.Type.Fn([Types.Type.Var("A"), Types.Type.Int], Types.Type.Var("B"))),
      ],
      result: Types.Type.Lazy(Types.Type.Var("B")),
      rule: Model.Rule.Plain,
      implementation: "__lazy_with_index",
      effects: [],
      description: "Internal to the prelude: a step or terminal of Lazy (vm/lazy.c).",
      alternatives: [],
    ),
    Model.Builtin(
      name: "__lazy_write_lines",
      parameters: [
        Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.String)),
        Model.Named(name: "path", type: Types.Type.String),
        Model.Named(name: "timeout_ms", type: Types.Type.Int),
      ],
      result: Types.Type.Result(Types.Type.Void),
      rule: Model.Rule.Plain,
      implementation: "__lazy_write_lines",
      effects: ["filesystem"],
      description: "Internal to the prelude: a step or terminal of Lazy (vm/lazy.c).",
      alternatives: [],
    ),
  ]

ROWS_54: List[Model.Builtin] = [
    Model.Builtin(
      name: "error",
      parameters: [Model.Named(name: "message", type: Types.Type.String)],
      result: Types.Type.Result(Types.Type.Var("T")),
      rule: Model.Rule.Error,
      implementation: "error",
      effects: [],
      description: "Construct an error; needs an expected Result type.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "gets",
      parameters: [],
      result: Types.Type.Result(Types.Type.String),
      rule: Model.Rule.Plain,
      implementation: "IO.gets",
      effects: ["stdin"],
      description: "Read a line as a Result; EOF is an error value.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "gets!",
      parameters: [],
      result: Types.Type.String,
      rule: Model.Rule.Plain,
      implementation: "IO.gets!",
      effects: ["stdin"],
      description: "Read a line; halt at EOF.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "ok",
      parameters: [Model.Named(name: "value", type: Types.Type.Var("T"))],
      result: Types.Type.Result(Types.Type.Var("T")),
      rule: Model.Rule.Ok,
      implementation: "ok",
      effects: [],
      description: "Construct a successful Result.",
      alternatives: [
        Model.Builtin(
          name: "ok",
          parameters: [],
          result: Types.Type.Result(Types.Type.Void),
          rule: Model.Rule.OkVoid,
          implementation: "ok",
          effects: [],
          description: "Construct successful completion.",
          alternatives: [],
        ),
      ],
    ),
  ]

ROWS_55: List[Model.Builtin] = [
    Model.Builtin(
      name: "print",
      parameters: [Model.Named(name: "value", type: Types.Type.Var("T"))],
      result: Types.Type.Void,
      rule: Model.Rule.Show,
      implementation: "IO.print",
      effects: ["stdout"],
      description: "Write a value without a newline; non-String values print as in interpolation.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "puts",
      parameters: [Model.Named(name: "value", type: Types.Type.Var("T"))],
      result: Types.Type.Void,
      rule: Model.Rule.Show,
      implementation: "puts",
      effects: ["stdout"],
      description: "Write a value and a newline; non-String values print as in interpolation.",
      alternatives: [],
    ),
  ]
