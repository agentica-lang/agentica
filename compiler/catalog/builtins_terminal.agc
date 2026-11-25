import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Terminal.raw",
    parameters: [Model.Named(name: "on", type: Types.Type.Bool, default: Model.Default.Flag(true))],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.Plain,
    implementation: "Terminal.raw",
    effects: ["stdin"],
    description: (
      "Put the terminal of standard input in raw mode (no echo, no line editing, no signals from keys, bytes in), " +
      "or with on: false give back the mode it had; the VM gives it back at exit too; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Terminal.size",
    parameters: [],
    result: Types.Type.Result(Types.Type.Struct("Terminal.Size", [])),
    rule: Model.Rule.Plain,
    implementation: "Terminal.size",
    effects: ["stdout"],
    description: "The rows and columns of the terminal of standard output, else of standard error; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Terminal.tty?",
    parameters: [Model.Named(name: "stream", type: Types.Type.Enum("Terminal.Stream", []))],
    result: Types.Type.Bool,
    rule: Model.Rule.Plain,
    implementation: "Terminal.tty?",
    effects: [],
    description: "Whether a standard stream is a terminal; VM only.",
    alternatives: [],
  ),
]
