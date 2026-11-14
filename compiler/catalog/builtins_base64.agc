import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Base64.encode64",
    parameters: [Model.Named(name: "data", type: Types.Type.Bytes)],
    result: Types.Type.String,
    rule: Model.Rule.Plain,
    implementation: "Base64.encode64.bytes",
    effects: [],
    description: (
      "Encode bytes as padded base64 (RFC 4648) in lines of 60 characters, each ending in a " +
      "newline, as Ruby does; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Base64.strict_encode64",
    parameters: [Model.Named(name: "data", type: Types.Type.Bytes)],
    result: Types.Type.String,
    rule: Model.Rule.Plain,
    implementation: "Base64.strict_encode64.bytes",
    effects: [],
    description: "Encode bytes as padded base64 (RFC 4648) on one line with no newline; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Base64.urlsafe_encode64",
    parameters: [
      Model.Named(name: "data", type: Types.Type.Bytes),
      Model.Named(name: "padding", type: Types.Type.Bool, default: Model.Default.Flag(true)),
    ],
    result: Types.Type.String,
    rule: Model.Rule.Plain,
    implementation: "Base64.urlsafe_encode64.bytes",
    effects: [],
    description: (
      "Encode bytes as base64url (RFC 4648 section 5), with the = padding unless padding is false; " +
      "VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Base64.decode64",
    parameters: [Model.Named(name: "text", type: Types.Type.String)],
    result: Types.Type.Bytes,
    rule: Model.Rule.Plain,
    implementation: "Base64.decode64.bytes",
    effects: [],
    description: (
      "Decode base64 leniently, as Ruby does: other characters are skipped and a = in a group's last two " +
      "places ends the text; never an error; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Base64.strict_decode64",
    parameters: [Model.Named(name: "text", type: Types.Type.String)],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "Base64.strict_decode64.bytes",
    effects: [],
    description: (
      "Decode padded base64 (RFC 4648) with nothing else in the text, or error(\"invalid base64\"); VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Base64.urlsafe_decode64",
    parameters: [Model.Named(name: "text", type: Types.Type.String)],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "Base64.urlsafe_decode64.bytes",
    effects: [],
    description: "Decode base64url (RFC 4648 section 5), padded or not, or error(\"invalid base64\"); VM only.",
    alternatives: [],
  ),
]
