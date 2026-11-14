import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Result.message",
    parameters: [Model.Named(name: "result", type: Types.Type.Result(Types.Type.Var("T")))],
    result: Types.Type.String,
    rule: Model.Rule.ResultMessage,
    implementation: "Result.message",
    effects: [],
    description: "Return an error message, or empty text for success.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Result.ok?",
    parameters: [Model.Named(name: "result", type: Types.Type.Result(Types.Type.Var("T")))],
    result: Types.Type.Bool,
    rule: Model.Rule.ResultOk,
    implementation: "Result.ok?",
    effects: [],
    description: "Check whether a Result succeeded.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Result.unwrap!",
    parameters: [Model.Named(name: "result", type: Types.Type.Result(Types.Type.Var("T")))],
    result: Types.Type.Var("T"),
    rule: Model.Rule.ResultUnwrap,
    implementation: "Result.unwrap!",
    effects: [],
    description: "Return the success value; halt on error.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Result.unwrap_or",
    parameters: [
      Model.Named(name: "result", type: Types.Type.Result(Types.Type.Var("T"))),
      Model.Named(name: "default", type: Types.Type.Var("T")),
    ],
    result: Types.Type.Var("T"),
    rule: Model.Rule.ResultDefault,
    implementation: "Result.unwrap_or",
    effects: [],
    description: "Return success or default; both arguments run eagerly.",
    alternatives: [],
  ),
]
