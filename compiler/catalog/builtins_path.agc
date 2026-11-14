import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
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
    parameters: [Model.Named(name: "list", type: Types.Type.List(Types.Type.String))],
    result: Types.Type.Result(Types.Type.String),
    rule: Model.Rule.Plain,
    implementation: "Path.join",
    effects: ["filesystem"],
    description: "Join path parts using host path semantics.",
    alternatives: [],
  ),
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
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
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
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
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
