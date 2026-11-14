import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "BddRandom.srand",
    parameters: [Model.Named(name: "seed", type: Types.Type.Int)],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "BddRandom.srand",
    effects: ["random"],
    description: (
      "Internal to std/bdd: start the running task's random numbers again from seed, as main's start under --seed."
    ),
    alternatives: [],
  ),
]
