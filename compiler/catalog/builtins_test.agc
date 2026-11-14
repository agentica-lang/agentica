import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Test.assert",
    parameters: [
      Model.Named(name: "condition", type: Types.Type.Bool),
      Model.Named(name: "message", type: Types.Type.String),
    ],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.Plain,
    implementation: "Test.assert",
    effects: ["test"],
    description: "Check a condition; a failure with message is recorded on the test.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Test.eq",
    parameters: [
      Model.Named(name: "actual", type: Types.Type.Var("T")),
      Model.Named(name: "expected", type: Types.Type.Var("T")),
    ],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.TestEq,
    implementation: "Test.eq",
    effects: ["test"],
    description: (
      "Compare two values of a type with equality (a JSON.Value as canonical text); a failure is recorded on the test."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Test.error?",
    parameters: [Model.Named(name: "result", type: Types.Type.Result(Types.Type.Var("T")))],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.TestResult,
    implementation: "Test.error?",
    effects: ["test"],
    description: "Check that a Result is an error; a failure is recorded on the test.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Test.ok?",
    parameters: [Model.Named(name: "result", type: Types.Type.Result(Types.Type.Var("T")))],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.TestResult,
    implementation: "Test.ok?",
    effects: ["test"],
    description: "Check that a Result is ok; a failure is recorded on the test.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Test.run",
    parameters: [Model.Named(name: "tests", type: Types.Type.List(Types.Type.Opaque("Test.Case")))],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "Test.run",
    effects: ["process", "concurrency"],
    description: "Serve agentica test: list the tests or run each in its own task; never returns.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Test.test",
    parameters: [
      Model.Named(name: "name", type: Types.Type.String),
      Model.Named(name: "body", type: Types.Type.Fn([], Types.Type.Result(Types.Type.Void))),
    ],
    result: Types.Type.Opaque("Test.Case"),
    rule: Model.Rule.Plain,
    implementation: "Test.test",
    effects: [],
    description: "Build a test case from a name and a block that returns Result[Void]; Test.run runs it.",
    alternatives: [],
  ),
]
