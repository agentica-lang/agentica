import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "FrontEnd.hand_off",
    parameters: [
      Model.Named(name: "program", type: Types.Type.Bytes),
      Model.Named(name: "options", type: Types.Type.List(Types.Type.String)),
      Model.Named(name: "arguments", type: Types.Type.List(Types.Type.String)),
    ],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.Plain,
    implementation: "FrontEnd.hand_off.bytes",
    effects: ["process"],
    description: (
      "Front end only: hand the compiled program, the VM options and the program arguments to the VM, which ends " +
      "this run and runs the program in a new one; it returns an error only when an argument cannot be passed on " +
      "(a program too large to load, or a character 0 in a word). Any other program fails with " +
      "RUNTIME-FRONT-END-ONLY."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "FrontEnd.std_source",
    parameters: [Model.Named(name: "path", type: Types.Type.String)],
    result: Types.Type.Result(Types.Type.String),
    rule: Model.Rule.Plain,
    implementation: "FrontEnd.std_source",
    effects: ["process"],
    description: (
      "Front end only: the text of an embedded std/ source, by its path in stdlib/ such as queue.agc or " +
      "bdd/gherkin.agc; an unknown path is an error. Any other program fails with RUNTIME-FRONT-END-ONLY."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "FrontEnd.stdin_bytes",
    parameters: [],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "FrontEnd.stdin_bytes.bytes",
    effects: ["process"],
    description: (
      "Front end only: standard input as bytes, read to its end (a later call reads on from there); more than " +
      "16 MiB, or a read that fails, is an error. The front end has no input stream otherwise. Any other program " +
      "fails with RUNTIME-FRONT-END-ONLY."
    ),
    alternatives: [],
  ),
]
