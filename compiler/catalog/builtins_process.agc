import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Process.channel_close",
    parameters: [
      Model.Named(name: "process", type: Types.Type.Opaque("Process")),
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
      Model.Named(name: "process", type: Types.Type.Opaque("Process")),
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
      Model.Named(name: "process", type: Types.Type.Opaque("Process")),
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
    parameters: [Model.Named(name: "process", type: Types.Type.Opaque("Process"))],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "Process.close",
    effects: ["subprocess"],
    description: "Kill and reap the child and close its streams idempotently.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Process.close_stdin",
    parameters: [
      Model.Named(name: "process", type: Types.Type.Opaque("Process")),
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
      Model.Named(name: "process", type: Types.Type.Opaque("Process")),
      Model.Named(name: "timeout_ms", type: Types.Type.Int),
    ],
    result: Types.Type.Result(Types.Type.Struct("Process.Output", [])),
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
  Model.Builtin(
    name: "Process.poll_line",
    parameters: [
      Model.Named(name: "process", type: Types.Type.Opaque("Process")),
      Model.Named(name: "timeout_ms", type: Types.Type.Int),
    ],
    result: Types.Type.Result(Types.Type.String),
    rule: Model.Rule.Plain,
    implementation: "Process.poll_line",
    effects: ["subprocess"],
    description: "Read a bounded UTF-8 line as read_line does, but a timeout keeps the program and its output.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Process.read_available",
    parameters: [
      Model.Named(name: "process", type: Types.Type.Opaque("Process")),
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
      Model.Named(name: "process", type: Types.Type.Opaque("Process")),
      Model.Named(name: "count", type: Types.Type.Int),
      Model.Named(name: "timeout_ms", type: Types.Type.Int),
    ],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "Process.read_bytes.bytes",
    effects: ["subprocess"],
    description: "Read count bytes or fewer at EOF; count is 0..1048576.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Process.read_line",
    parameters: [
      Model.Named(name: "process", type: Types.Type.Opaque("Process")),
      Model.Named(name: "timeout_ms", type: Types.Type.Int),
    ],
    result: Types.Type.Result(Types.Type.String),
    rule: Model.Rule.Plain,
    implementation: "Process.read_line",
    effects: ["subprocess"],
    description: "Read a bounded UTF-8 line; empty EOF is an error.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Process.send",
    parameters: [
      Model.Named(name: "process", type: Types.Type.Opaque("Process")),
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
      Model.Named(name: "process", type: Types.Type.Opaque("Process")),
      Model.Named(name: "bytes", type: Types.Type.Bytes),
      Model.Named(name: "timeout_ms", type: Types.Type.Int),
    ],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.Plain,
    implementation: "Process.send_bytes.bytes",
    effects: ["subprocess"],
    description: "Send at most 1 MiB of bytes and flush.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Process.spawn",
    parameters: [
      Model.Named(name: "command", type: Types.Type.String),
      Model.Named(name: "args", type: Types.Type.List(Types.Type.String)),
      Model.Named(
        name: "options",
        type: Types.Type.Struct("Process.Options", []),
        default: Model.Default.Fields("Process.Options"),
      ),
    ],
    result: Types.Type.Result(Types.Type.Opaque("Process")),
    rule: Model.Rule.Plain,
    implementation: "Process.spawn.options",
    effects: ["subprocess"],
    description: (
      "Start an executable with literal arguments and Process.Options: timeout_ms, chdir, extra env entries, out " +
      "and err files that get its stdout and stderr when not empty, and pgroup to start it in its own process " +
      "group, which a stop signals whole; --deny-run makes it an error."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Process.spawn_captured",
    parameters: [
      Model.Named(name: "command", type: Types.Type.String),
      Model.Named(name: "args", type: Types.Type.List(Types.Type.String)),
      Model.Named(
        name: "options",
        type: Types.Type.Struct("Process.Options", []),
        default: Model.Default.Fields("Process.Options"),
      ),
    ],
    result: Types.Type.Result(Types.Type.Opaque("Process")),
    rule: Model.Rule.Plain,
    implementation: "Process.spawn_captured.options",
    effects: ["subprocess"],
    description: (
      "Start an executable with Process.Options and stdout and stderr kept in 1 MiB buffers; out or err is an " +
      "error; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Process.spawn_channel",
    parameters: [
      Model.Named(name: "command", type: Types.Type.String),
      Model.Named(name: "args", type: Types.Type.List(Types.Type.String)),
      Model.Named(
        name: "options",
        type: Types.Type.Struct("Process.Options", []),
        default: Model.Default.Fields("Process.Options"),
      ),
    ],
    result: Types.Type.Result(Types.Type.Opaque("Process")),
    rule: Model.Rule.Plain,
    implementation: "Process.spawn_channel.options",
    effects: ["subprocess"],
    description: (
      "Like spawn_captured, plus a channel: the child reads fd 3, writes fd 4, has AGENTICA_CHANNEL=3,4; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Process.wait",
    parameters: [
      Model.Named(name: "process", type: Types.Type.Opaque("Process")),
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
    name: "Process.signal",
    parameters: [
      Model.Named(name: "process", type: Types.Type.Opaque("Process")),
      Model.Named(name: "signal", type: Types.Type.Enum("System.Signal", [])),
    ],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.Plain,
    implementation: "Process.signal",
    effects: ["subprocess"],
    description: "Send a signal to the child; a closed or exited child is an error; POSIX, VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Process.spawn_group",
    parameters: [
      Model.Named(name: "command", type: Types.Type.String),
      Model.Named(name: "args", type: Types.Type.List(Types.Type.String)),
      Model.Named(name: "dir", type: Types.Type.String, default: Model.Default.Text(".")),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
    ],
    result: Types.Type.Result(Types.Type.Opaque("Process")),
    rule: Model.Rule.Plain,
    implementation: "Process.spawn_group",
    effects: ["subprocess"],
    description: (
      "Start an executable in a new session, so it leads its own process group, with the program's stdin, stdout " +
      "and stderr; Process.close and the end of the run kill the whole group; --deny-run makes it an error; POSIX, " +
      "VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Process.signal_group",
    parameters: [
      Model.Named(name: "process", type: Types.Type.Opaque("Process")),
      Model.Named(name: "signal", type: Types.Type.Enum("System.Signal", [])),
    ],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.Plain,
    implementation: "Process.signal_group",
    effects: ["subprocess"],
    description: (
      "Send a signal to the process group that the child leads (Process.spawn_group, or pgroup: true); an error " +
      "once the child has exited; POSIX, VM only."
    ),
    alternatives: [],
  ),
]
