import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Term.encode",
    parameters: [Model.Named(name: "value", type: Types.Type.Var("T"))],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.TermEncode,
    implementation: "Term.encode",
    effects: [],
    description: (
      "Encode a value in CBOR (RFC 8949), deterministically: the types of the value are the schema; " +
      "a value past a limit returns an error; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Term.decode",
    parameters: [
      Model.Named(name: "data", type: Types.Type.Bytes),
      Model.Named(name: "type", type: Types.Type.Var("T")),
    ],
    result: Types.Type.Result(Types.Type.Var("T")),
    rule: Model.Rule.TermDecode,
    implementation: "Term.decode",
    effects: [],
    description: (
      "Decode CBOR (RFC 8949) written by Term.encode into a named struct or enum; " +
      "invalid data returns an error; VM only."
    ),
    alternatives: [],
  ),
]
