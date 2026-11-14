import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "System.Profile.measure",
    parameters: [
      Model.Named(name: "label", type: Types.Type.String),
      Model.Named(name: "block", type: Types.Type.Fn([], Types.Type.Var("T"))),
    ],
    result: Types.Type.Var("T"),
    rule: Model.Rule.ProfileMeasure,
    implementation: "Profile.measure",
    effects: [],
    description: (
      "Run the block and return its value; with AGENTICA_VM_TRACE=profile, its calls, steps, time and GC time " +
      "go to a section row of the profile under label; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "System.Profile.steps",
    parameters: [],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "Profile.steps",
    effects: [],
    description: "Count the steps this task has run so far; the same on every run, with or without the profile.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "System.args",
    parameters: [],
    result: Types.Type.List(Types.Type.String),
    rule: Model.Rule.Plain,
    implementation: "System.args",
    effects: ["process"],
    description: "Return program arguments.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "System.env",
    parameters: [Model.Named(name: "name", type: Types.Type.String)],
    result: Types.Type.Result(Types.Type.String),
    rule: Model.Rule.Plain,
    implementation: "System.env",
    effects: ["process"],
    description: (
      "Read an environment variable; an unset variable or an invalid name returns an error, and an empty value " +
      "returns ok."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "System.exit",
    parameters: [Model.Named(name: "code", type: Types.Type.Int)],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "System.exit",
    effects: ["process"],
    description: "End the run with an exit code.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "System.os",
    parameters: [],
    result: Types.Type.String,
    rule: Model.Rule.Plain,
    implementation: "System.os",
    effects: ["process"],
    description: (
      "Return the operating system: linux, macos, windows, or the lowercase name uname gives on another system; " +
      "VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "System.pid",
    parameters: [],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "System.pid",
    effects: ["process"],
    description: "Return the process id of this program; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "System.subscribe",
    parameters: [Model.Named(name: "signals", type: Types.Type.List(Types.Type.Enum("System.Signal", [])))],
    result: Types.Type.Result(Types.Type.Channel(Types.Type.Enum("System.Signal", []))),
    rule: Model.Rule.Plain,
    implementation: "System.subscribe",
    effects: ["process"],
    description: (
      "Receive the listed OS signals on a new channel (one pending value per signal) instead of stopping the " +
      "program; the calling task owns it, and its end or Channel.close ends the subscription; Quit and Kill are " +
      "RUNTIME-INVALID-SIGNAL; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "System.signal_number",
    parameters: [Model.Named(name: "signal", type: Types.Type.Enum("System.Signal", []))],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "System.signal_number",
    effects: [],
    description: "The OS number of a signal (Term is 15), so 128 + it is the exit code a signal gives; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "System.signal",
    parameters: [
      Model.Named(name: "pid", type: Types.Type.Int),
      Model.Named(name: "signal", type: Types.Type.Enum("System.Signal", [])),
      Model.Named(name: "comm", type: Types.Type.String),
    ],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.Plain,
    implementation: "System.signal",
    effects: ["process"],
    description: (
      "Send a signal to the process PID only while its name (/proc/PID/comm, at most 15 bytes) is comm, through a " +
      "pidfd so it never reaches another process; --deny-run makes it an error; Linux 5.3 or later, VM only."
    ),
    alternatives: [],
  ),
]
