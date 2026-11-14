import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Codec.decode",
    parameters: [
      Model.Named(name: "codec", type: Types.Type.Codec(Types.Type.Var("T"))),
      Model.Named(name: "text", type: Types.Type.String),
    ],
    result: Types.Type.Result(Types.Type.Var("T")),
    rule: Model.Rule.CodecDecode,
    implementation: "JSON.decode",
    effects: [],
    description: "Decode JSON text into the codec's struct, as JSON.decode does.",
    alternatives: [
      Model.Builtin(
        name: "Codec.decode",
        parameters: [
          Model.Named(name: "codec", type: Types.Type.Codec(Types.Type.Var("T"))),
          Model.Named(name: "json", type: Types.Type.Json),
        ],
        result: Types.Type.Result(Types.Type.Var("T")),
        rule: Model.Rule.CodecDecode,
        implementation: "JSON.decode",
        effects: [],
        description: "Decode a JSON.Value into the codec's struct, as JSON.decode does.",
        alternatives: [],
      ),
    ],
  ),
  Model.Builtin(
    name: "Codec.encode",
    parameters: [
      Model.Named(name: "codec", type: Types.Type.Codec(Types.Type.Var("T"))),
      Model.Named(name: "value", type: Types.Type.Var("T")),
    ],
    result: Types.Type.String,
    rule: Model.Rule.CodecEncode,
    implementation: "JSON.encode",
    effects: [],
    description: "Encode a value of the codec's struct as JSON text, as JSON.encode does.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Codec.from",
    parameters: [
      Model.Named(name: "codec", type: Types.Type.Codec(Types.Type.Var("T"))),
      Model.Named(name: "value", type: Types.Type.Var("T")),
    ],
    result: Types.Type.Json,
    rule: Model.Rule.CodecEncode,
    implementation: "JSON.from",
    effects: [],
    description: "Convert a value of the codec's struct to a JSON.Value, as JSON.from does.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Codec.members",
    parameters: [Model.Named(name: "codec", type: Types.Type.Codec(Types.Type.Var("T")))],
    result: Types.Type.List(Types.Type.Struct("StructMember", [])),
    rule: Model.Rule.CodecMembers,
    implementation: "Codec.members",
    effects: [],
    description: "The fields of the codec's struct, as T.members gives them; empty for an enum.",
    alternatives: [],
  ),
]
