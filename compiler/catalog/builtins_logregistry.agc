import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "LogRegistry.attach",
    parameters: [
      Model.Named(name: "name", type: Types.Type.String),
      Model.Named(name: "rank", type: Types.Type.Int),
      Model.Named(name: "handler", type: Types.Type.Fn([Types.Type.Struct("LogRegistry.Event", [])], Types.Type.Void)),
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
    result: Types.Type.List(Types.Type.Fn([Types.Type.Struct("LogRegistry.Event", [])], Types.Type.Void)),
    rule: Model.Rule.Plain,
    implementation: "LogRegistry.handlers",
    effects: ["logging"],
    description: "Internal to std/logger: the handlers whose rank is at or below the given rank, in attach order.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "LogRegistry.install_default",
    parameters: [
      Model.Named(name: "handler", type: Types.Type.Fn([Types.Type.Struct("LogRegistry.Event", [])], Types.Type.Void)),
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
]
