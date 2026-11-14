import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "File.append_text",
    parameters: [
      Model.Named(name: "path", type: Types.Type.String),
      Model.Named(name: "text", type: Types.Type.String),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
    ],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.Plain,
    implementation: "File.append_text",
    effects: ["filesystem"],
    description: "Append at most 1 MiB of UTF-8 text.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "File.chunks",
    parameters: [
      Model.Named(name: "path", type: Types.Type.String),
      Model.Named(name: "size", type: Types.Type.Int, default: Model.Default.Whole(65536)),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
    ],
    result: Types.Type.Lazy(Types.Type.Bytes),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: (
      "Source: the bytes of a regular file in chunks of size bytes (1 to 16777216), the last one shorter; the " +
      "file opens when a terminal starts and closes before it returns; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "File.close",
    parameters: [
      Model.Named(name: "handle", type: Types.Type.Opaque("File.Handle")),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
    ],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.Plain,
    implementation: "File.close",
    effects: ["filesystem"],
    description: "Flush and close a file handle idempotently.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "File.each_line",
    parameters: [
      Model.Named(name: "path", type: Types.Type.String),
      Model.Named(name: "buffer_bytes", type: Types.Type.Int, default: Model.Default.Whole(65536)),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
      Model.Named(name: "block", type: Types.Type.Fn([Types.Type.String], Types.Type.Result(Types.Type.Void))),
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
      Model.Named(name: "handle", type: Types.Type.Opaque("File.Handle")),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
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
      Model.Named(name: "buffer_bytes", type: Types.Type.Int, default: Model.Default.Whole(65536)),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
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
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
    ],
    result: Types.Type.Result(Types.Type.Struct("File.Info", [])),
    rule: Model.Rule.Plain,
    implementation: "File.lstat",
    effects: ["filesystem"],
    description: "Like File.stat, but a symbolic link is described itself and has kind \"link\"; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "File.open",
    parameters: [
      Model.Named(name: "path", type: Types.Type.String),
      Model.Named(name: "mode", type: Types.Type.String, default: Model.Default.Text("read")),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
    ],
    result: Types.Type.Result(Types.Type.Opaque("File.Handle")),
    rule: Model.Rule.Plain,
    implementation: "File.open",
    effects: ["filesystem"],
    description: (
      "Open a regular file for read, write, append or create_private with a deadline; create_private makes a new " +
      "file only the current user can use and fails when the path exists."
    ),
    alternatives: [
      Model.Builtin(
        name: "File.open",
        parameters: [
          Model.Named(name: "path", type: Types.Type.String),
          Model.Named(name: "mode", type: Types.Type.String, default: Model.Default.Text("read")),
          Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
          Model.Named(
            name: "block",
            type: Types.Type.Fn([Types.Type.Opaque("File.Handle")], Types.Type.Result(Types.Type.Var("A"))),
          ),
        ],
        result: Types.Type.Result(Types.Type.Var("A")),
        rule: Model.Rule.Prelude,
        implementation: "",
        effects: ["filesystem"],
        description: (
          "Open the file, call the block with the handle, and close the handle when the block ends, with ok or " +
          "error; gives the block's Result, or the close error after an ok block; VM only."
        ),
        alternatives: [],
      ),
    ],
  ),
  Model.Builtin(
    name: "File.read_bytes",
    parameters: [
      Model.Named(name: "handle", type: Types.Type.Opaque("File.Handle")),
      Model.Named(name: "max_bytes", type: Types.Type.Int),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
    ],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "File.read_bytes.bytes",
    effects: ["filesystem"],
    description: "Read up to max_bytes; empty means EOF.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "File.read_line",
    parameters: [
      Model.Named(name: "handle", type: Types.Type.Opaque("File.Handle")),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
    ],
    result: Types.Type.Result(Types.Type.String),
    rule: Model.Rule.Plain,
    implementation: "File.read_line",
    effects: ["filesystem"],
    description: "Read one bounded UTF-8 line, removing LF or CRLF.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "File.read_text",
    parameters: [
      Model.Named(name: "path", type: Types.Type.String),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
    ],
    result: Types.Type.Result(Types.Type.String),
    rule: Model.Rule.Plain,
    implementation: "File.read_text",
    effects: ["filesystem"],
    description: "Read and strictly decode at most 1 MiB of UTF-8 text.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "File.replace",
    parameters: [
      Model.Named(name: "path", type: Types.Type.String),
      Model.Named(name: "data", type: Types.Type.Bytes),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
    ],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.Plain,
    implementation: "File.replace",
    effects: ["filesystem"],
    description: (
      "Replace the existing regular file at path, after its symbolic links, with at most 16 MiB of data in one " +
      "step; the file keeps its permission bits and a link stays a link; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "File.sha256",
    parameters: [
      Model.Named(name: "path", type: Types.Type.String),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
    ],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "File.sha256.bytes",
    effects: ["filesystem"],
    description: (
      "Hash the whole file at path with SHA-256, streaming in fixed chunks, and return the 32 digest bytes; " +
      "VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "File.stat",
    parameters: [
      Model.Named(name: "path", type: Types.Type.String),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
    ],
    result: Types.Type.Result(Types.Type.Struct("File.Info", [])),
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
      Model.Named(name: "handle", type: Types.Type.Opaque("File.Handle")),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
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
  Model.Builtin(
    name: "File.write",
    parameters: [
      Model.Named(name: "handle", type: Types.Type.Opaque("File.Handle")),
      Model.Named(name: "text", type: Types.Type.String),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
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
      Model.Named(name: "handle", type: Types.Type.Opaque("File.Handle")),
      Model.Named(name: "bytes", type: Types.Type.Bytes),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
    ],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.Plain,
    implementation: "File.write_bytes.bytes",
    effects: ["filesystem"],
    description: "Write bytes, at most 1 MiB per call.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "File.write_text",
    parameters: [
      Model.Named(name: "path", type: Types.Type.String),
      Model.Named(name: "text", type: Types.Type.String),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
    ],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.Plain,
    implementation: "File.write_text",
    effects: ["filesystem"],
    description: "Overwrite a file with at most 1 MiB of UTF-8 text.",
    alternatives: [],
  ),
]
