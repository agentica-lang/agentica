import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Address.send",
    parameters: [
      Model.Named(name: "address", type: Types.Type.Address(Types.Type.Var("T"))),
      Model.Named(name: "value", type: Types.Type.Var("T")),
      Model.Named(name: "timeout_ms", type: Types.Type.Int),
    ],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.AddressSend,
    implementation: "Address.send",
    effects: ["concurrency"],
    description: (
      "Send to the channel of the address as Channel#send does; error(\"address: gone\") once the channel is " +
      "collected; VM only."
    ),
    alternatives: [],
  ),
]
