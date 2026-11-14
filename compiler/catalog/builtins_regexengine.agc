import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "RegexEngine.search",
    parameters: [
      Model.Named(name: "text", type: Types.Type.String),
      Model.Named(name: "ops", type: Types.Type.List(Types.Type.Int)),
      Model.Named(name: "xs", type: Types.Type.List(Types.Type.Int)),
      Model.Named(name: "ys", type: Types.Type.List(Types.Type.Int)),
      Model.Named(name: "classes", type: Types.Type.List(Types.Type.List(Types.Type.Int))),
      Model.Named(name: "ncap", type: Types.Type.Int),
      Model.Named(name: "mode", type: Types.Type.Int),
    ],
    result: Types.Type.List(Types.Type.Int),
    rule: Model.Rule.Plain,
    implementation: "RegexEngine.search",
    effects: [],
    description: "Internal to std/regex: run a compiled program; mode 0 gives the first end, 1 the captures, 2 all.",
    alternatives: [],
  ),
]
