import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Error.is_a?",
    parameters: [
      Model.Named(name: "error", type: Types.Type.Struct("Error", [])),
      Model.Named(name: "family", type: Types.Type.String),
    ],
    result: Types.Type.Bool,
    rule: Model.Rule.ErrorKind,
    implementation: "Error.is_a?",
    effects: [],
    description: "Whether the kind is the family or one of its dotted kinds: is_a?(\"db\") takes db.constraint.",
    alternatives: [],
  ),
]
