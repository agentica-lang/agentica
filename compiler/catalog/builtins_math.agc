import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Math.sqrt",
    parameters: [Model.Named(name: "float", type: Types.Type.Float)],
    result: Types.Type.Float,
    rule: Model.Rule.Plain,
    implementation: "Math.sqrt",
    effects: [],
    description: "The square root; a negative float halts; -0.0 gives -0.0 and NaN stays NaN.",
    alternatives: [],
  ),
]
