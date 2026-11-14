import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "DNS.lookup",
    parameters: [
      Model.Named(name: "host", type: Types.Type.String),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
    ],
    result: Types.Type.Result(Types.Type.List(Types.Type.String)),
    rule: Model.Rule.Plain,
    implementation: "DNS.lookup",
    effects: ["network"],
    description: (
      "Resolve a host name with the system resolver: every IPv4 and IPv6 address as text, in its order, without " +
      "duplicates; an IP literal gives itself."
    ),
    alternatives: [],
  ),
]
