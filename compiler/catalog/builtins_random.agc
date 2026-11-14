import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Random.float",
    parameters: [],
    result: Types.Type.Float,
    rule: Model.Rule.Plain,
    implementation: "Random.float",
    effects: ["random"],
    description: "Pick a uniform Float in 0.0 up to, but not including, 1.0.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Random.int",
    parameters: [Model.Named(name: "min", type: Types.Type.Int), Model.Named(name: "max", type: Types.Type.Int)],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "Random.int",
    effects: ["random"],
    description: "Pick a uniform Int in min..max inclusive; min > max halts.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Random.seed",
    parameters: [],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "Random.seed",
    effects: ["random"],
    description: (
      "The seed of the run, 0..2147483647: the one --seed gave, or the one drawn from the system when there is " +
      "none; the same in every task, so --seed with it gives the same random numbers."
    ),
    alternatives: [],
  ),
]
