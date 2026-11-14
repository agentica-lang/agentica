import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "ATS.add",
    parameters: [
      Model.Named(name: "table", type: Types.Type.ATS(Types.Type.Var("K"), Types.Type.Int)),
      Model.Named(name: "key", type: Types.Type.Var("K")),
      Model.Named(name: "by", type: Types.Type.Int),
    ],
    result: Types.Type.Int,
    rule: Model.Rule.AtsCall,
    implementation: "ATS.add",
    effects: ["concurrency"],
    description: (
      "Add the amount by to the Int value of key (absent counts as 0) and return the new value, atomically; " +
      "overflow halts with RUNTIME-INTEGER-OVERFLOW and leaves the table unchanged; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "ATS.delete",
    parameters: [
      Model.Named(name: "table", type: Types.Type.ATS(Types.Type.Var("K"), Types.Type.Var("V"))),
      Model.Named(name: "key", type: Types.Type.Var("K")),
    ],
    result: Types.Type.Void,
    rule: Model.Rule.AtsCall,
    implementation: "ATS.delete",
    effects: ["concurrency"],
    description: "Remove a key atomically; an absent key is ignored; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "ATS.get",
    parameters: [
      Model.Named(name: "table", type: Types.Type.ATS(Types.Type.Var("K"), Types.Type.Var("V"))),
      Model.Named(name: "key", type: Types.Type.Var("K")),
    ],
    result: Types.Type.Result(Types.Type.Var("V")),
    rule: Model.Rule.AtsCall,
    implementation: "ATS.get",
    effects: [],
    description: "Read the value of a key, or an error when the key is absent; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "ATS.has_key?",
    parameters: [
      Model.Named(name: "table", type: Types.Type.ATS(Types.Type.Var("K"), Types.Type.Var("V"))),
      Model.Named(name: "key", type: Types.Type.Var("K")),
    ],
    result: Types.Type.Bool,
    rule: Model.Rule.AtsCall,
    implementation: "ATS.has_key?",
    effects: [],
    description: "Check whether a key exists; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "ATS.keys",
    parameters: [Model.Named(name: "table", type: Types.Type.ATS(Types.Type.Var("K"), Types.Type.Var("V")))],
    result: Types.Type.List(Types.Type.Var("K")),
    rule: Model.Rule.AtsCall,
    implementation: "ATS.keys",
    effects: [],
    description: "A snapshot of the keys in first-insertion order; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "ATS.new",
    parameters: [],
    result: Types.Type.ATS(Types.Type.Var("K"), Types.Type.Var("V")),
    rule: Model.Rule.AtsNew,
    implementation: "ATS.new",
    effects: [],
    description: "Create an empty shared table that tasks update in place; needs an expected ATS[K, V] type; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "ATS.put",
    parameters: [
      Model.Named(name: "table", type: Types.Type.ATS(Types.Type.Var("K"), Types.Type.Var("V"))),
      Model.Named(name: "key", type: Types.Type.Var("K")),
      Model.Named(name: "value", type: Types.Type.Var("V")),
    ],
    result: Types.Type.Void,
    rule: Model.Rule.AtsCall,
    implementation: "ATS.put",
    effects: ["concurrency"],
    description: "Insert or replace the value of a key atomically; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "ATS.put_new",
    parameters: [
      Model.Named(name: "table", type: Types.Type.ATS(Types.Type.Var("K"), Types.Type.Var("V"))),
      Model.Named(name: "key", type: Types.Type.Var("K")),
      Model.Named(name: "value", type: Types.Type.Var("V")),
    ],
    result: Types.Type.Bool,
    rule: Model.Rule.AtsCall,
    implementation: "ATS.put_new",
    effects: ["concurrency"],
    description: (
      "Insert the value only when the key is absent, atomically; false leaves the table unchanged; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "ATS.size",
    parameters: [Model.Named(name: "table", type: Types.Type.ATS(Types.Type.Var("K"), Types.Type.Var("V")))],
    result: Types.Type.Int,
    rule: Model.Rule.AtsCall,
    implementation: "ATS.size",
    effects: [],
    description: "Count the entries of the table (a snapshot); VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "ATS.to_map",
    parameters: [Model.Named(name: "table", type: Types.Type.ATS(Types.Type.Var("K"), Types.Type.Var("V")))],
    result: Types.Type.Map(Types.Type.Var("K"), Types.Type.Var("V")),
    rule: Model.Rule.AtsCall,
    implementation: "ATS.to_map",
    effects: [],
    description: "A snapshot of the table as a Map in first-insertion order; VM only.",
    alternatives: [],
  ),
]
