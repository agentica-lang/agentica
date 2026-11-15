import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "BddScenario.srand",
    parameters: [Model.Named(name: "seed", type: Types.Type.Int)],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "BddScenario.srand",
    effects: ["random"],
    description: (
      "Internal to std/bdd: start the running task's random numbers again from seed, as main's start under --seed."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "BddScenario.uncount",
    parameters: [],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "BddScenario.uncount",
    effects: ["concurrency"],
    description: "Internal to std/bdd: the running task leaves Task.pending_count, as main is out of it.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "BddScenario.budget",
    parameters: [Model.Named(name: "steps", type: Types.Type.Int)],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "BddScenario.budget",
    effects: ["concurrency"],
    description: "Internal to std/bdd: the run has steps left from here, as a run started with --max-steps steps.",
    alternatives: [],
  ),
]
