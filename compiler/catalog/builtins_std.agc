import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Std.source",
    parameters: [Model.Named(name: "path", type: Types.Type.String)],
    result: Types.Type.Result(Types.Type.String),
    rule: Model.Rule.Plain,
    implementation: "Std.source",
    effects: [],
    description: (
      "The text of a std/ source that this binary carries, by its path in stdlib/ such as queue.agc, " +
      "bdd/gherkin.agc or prelude/list.agc; an unknown path is an error."
    ),
    alternatives: [],
  ),
]
