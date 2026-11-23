import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Ref.make",
    parameters: [],
    result: Types.Type.Opaque("Ref"),
    rule: Model.Rule.Plain,
    implementation: "Ref.make",
    effects: [],
    description: (
      "Return a new Ref, equal only to itself and unique in the run; Refs sort in the order they were made, so a " +
      "Ref made after another sorts after it; VM only."
    ),
    alternatives: [],
  ),
]
