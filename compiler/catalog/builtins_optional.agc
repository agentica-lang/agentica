import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Optional.map",
    parameters: [
      Model.Named(name: "optional", type: Types.Type.Optional(Types.Type.Var("T"))),
      Model.Named(name: "block", type: Types.Type.Fn([Types.Type.Var("T")], Types.Type.Var("U"))),
    ],
    result: Types.Type.Optional(Types.Type.Var("U")),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "some(block(x)) for some(x), else none; block runs only for some.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Optional.none?",
    parameters: [Model.Named(name: "optional", type: Types.Type.Optional(Types.Type.Var("T")))],
    result: Types.Type.Bool,
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Check whether the value is none.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Optional.some?",
    parameters: [Model.Named(name: "optional", type: Types.Type.Optional(Types.Type.Var("T")))],
    result: Types.Type.Bool,
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Check whether the value is some(x).",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Optional.to_result",
    parameters: [
      Model.Named(name: "optional", type: Types.Type.Optional(Types.Type.Var("T"))),
      Model.Named(name: "message", type: Types.Type.String),
    ],
    result: Types.Type.Result(Types.Type.Var("T")),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "ok(x) for some(x), else error(message), to join try code.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Optional.unwrap!",
    parameters: [Model.Named(name: "optional", type: Types.Type.Optional(Types.Type.Var("T")))],
    result: Types.Type.Var("T"),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Return x of some(x); halt on none.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Optional.unwrap_or",
    parameters: [
      Model.Named(name: "optional", type: Types.Type.Optional(Types.Type.Var("T"))),
      Model.Named(name: "default", type: Types.Type.Var("T")),
    ],
    result: Types.Type.Var("T"),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Return x of some(x), else default; both arguments run eagerly.",
    alternatives: [],
  ),
]
