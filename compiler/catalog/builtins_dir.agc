import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Dir.list",
    parameters: [
      Model.Named(name: "path", type: Types.Type.String),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
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
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
    ],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.Plain,
    implementation: "Dir.mkdir",
    effects: ["filesystem"],
    description: "Create a directory and missing parents; existing directories succeed.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Dir.mkdir_private",
    parameters: [
      Model.Named(name: "path", type: Types.Type.String),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
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
]
