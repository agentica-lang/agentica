import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Time.monotonic_ms",
    parameters: [],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "Time.monotonic_ms",
    effects: ["clock"],
    description: "Read milliseconds from an arbitrary origin that never goes backward; use for durations.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Time.monotonic_ns",
    parameters: [],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "Time.monotonic_ns",
    effects: ["clock"],
    description: (
      "Read nanoseconds from the clock of Time.monotonic_ms; same origin, never goes backward; use for short " +
      "durations."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Time.now_ms",
    parameters: [],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "Time.now_ms",
    effects: ["clock"],
    description: "Read wall-clock milliseconds since the Unix epoch; may jump.",
    alternatives: [],
  ),
]
