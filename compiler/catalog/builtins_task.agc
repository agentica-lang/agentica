import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Task.await",
    parameters: [Model.Named(name: "task", type: Types.Type.Task(Types.Type.Var("R")))],
    result: Types.Type.Var("R"),
    rule: Model.Rule.TaskAwait,
    implementation: "Task.await",
    effects: ["concurrency"],
    description: (
      "Wait for a task and return its cached result; a crashed task gives error(text) when R is a Result, else " +
      "RUNTIME-TASK-CRASHED."
    ),
    alternatives: [
      Model.Builtin(
        name: "Task.await",
        parameters: [
          Model.Named(name: "task", type: Types.Type.Task(Types.Type.Var("R"))),
          Model.Named(name: "timeout_ms", type: Types.Type.Int),
        ],
        result: Types.Type.Enum("Await", [Types.Type.Var("R")]),
        rule: Model.Rule.TaskAwaitTimeout,
        implementation: "Task.await",
        effects: ["concurrency"],
        description: (
          "Wait for a task for at most timeout_ms; Await.Done(value) with its cached result, or Await.TimedOut, " +
          "and the task keeps running; timeout_ms must be positive."
        ),
        alternatives: [],
      ),
    ],
  ),
  Model.Builtin(
    name: "Task.cancel",
    parameters: [Model.Named(name: "task", type: Types.Type.Task(Types.Type.Var("R")))],
    result: Types.Type.Void,
    rule: Model.Rule.TaskTarget,
    implementation: "Task.cancel",
    effects: ["concurrency"],
    description: (
      "Cancel a task (or TaskRef) and its descendants without waiting: each runs at most the rest of its current " +
      "turn and closes what it owns; does nothing for a task that has ended; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Task.map",
    parameters: [
      Model.Named(name: "items", type: Types.Type.List(Types.Type.Var("A"))),
      Model.Named(name: "limit", type: Types.Type.Int),
      Model.Named(name: "timeout_ms", type: Types.Type.Int),
      Model.Named(name: "block", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Result(Types.Type.Var("R")))),
    ],
    result: Types.Type.List(Types.Type.Result(Types.Type.Var("R"))),
    rule: Model.Rule.TaskMap,
    implementation: "Task.map",
    effects: ["concurrency"],
    description: (
      "Run the block for each item in its own task, at most limit (1 to 1024) at a time, each with its own " +
      "timeout_ms (positive, from the start of that item); gives one Result per item in input order, an error " +
      "(task: timed out) for an item that ran out of time, which is cancelled; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Task.pending_count",
    parameters: [],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "Task.pending_count",
    effects: ["concurrency"],
    description: "Count the tasks of this run that have not ended, not counting main; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Task.sleep",
    parameters: [Model.Named(name: "milliseconds", type: Types.Type.Int)],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "Task.sleep",
    effects: ["concurrency"],
    description: "Suspend this task for nonnegative milliseconds; zero yields execution.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Task.spawn",
    parameters: [Model.Named(name: "function", type: Types.Type.Fn([], Types.Type.Var("R")))],
    result: Types.Type.Task(Types.Type.Var("R")),
    rule: Model.Rule.TaskSpawn,
    implementation: "Task.spawn",
    effects: ["concurrency"],
    description: "Start a function with no argument in a lightweight task.",
    alternatives: [
      Model.Builtin(
        name: "Task.spawn",
        parameters: [
          Model.Named(name: "function", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Var("R"))),
          Model.Named(name: "argument", type: Types.Type.Var("A")),
        ],
        result: Types.Type.Task(Types.Type.Var("R")),
        rule: Model.Rule.TaskSpawn,
        implementation: "Task.spawn",
        effects: ["concurrency"],
        description: "Start a function with one argument in a lightweight task.",
        alternatives: [],
      ),
    ],
  ),
  Model.Builtin(
    name: "Task.spawn_owning",
    parameters: [
      Model.Named(name: "function", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Var("R"))),
      Model.Named(name: "handle", type: Types.Type.Var("A")),
    ],
    result: Types.Type.Task(Types.Type.Var("R")),
    rule: Model.Rule.TaskSpawnOwning,
    implementation: "Task.spawn_owning",
    effects: ["concurrency"],
    description: (
      "Like Task.spawn, and gives the handle or Channel argument, or every one that a struct, enum, List, Map " +
      "or Result argument holds, to the new task; the calling task must own each one (an unowned Channel " +
      "counts); VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Task.unobserved_crash",
    parameters: [],
    result: Types.Type.Result(Types.Type.String),
    rule: Model.Rule.Plain,
    implementation: "Task.unobserved_crash",
    effects: ["concurrency"],
    description: "Return the text of the first task crash no await has observed, or an error.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Task.current",
    parameters: [],
    result: Types.Type.Opaque("TaskRef"),
    rule: Model.Rule.Plain,
    implementation: "Task.current",
    effects: ["concurrency"],
    description: (
      "Return the running task as a TaskRef, which Task.monitor, Task.cancel and id take but no await, since its " +
      "result type is not known here; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Task.id",
    parameters: [Model.Named(name: "task", type: Types.Type.Task(Types.Type.Var("R")))],
    result: Types.Type.Int,
    rule: Model.Rule.TaskTarget,
    implementation: "Task.id",
    effects: [],
    description: "Return the number that identifies the task (or TaskRef) in this run, the task_id of its TaskDown.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Task.monitor",
    parameters: [
      Model.Named(name: "task", type: Types.Type.Task(Types.Type.Var("R"))),
      Model.Named(name: "channel", type: Types.Type.Channel(Types.Type.Var("M"))),
      Model.Named(name: "message", type: Types.Type.Fn([Types.Type.Struct("TaskDown", [])], Types.Type.Var("M"))),
    ],
    result: Types.Type.Void,
    rule: Model.Rule.TaskMonitor,
    implementation: "Task.monitor",
    effects: ["concurrency"],
    description: (
      "When the task (or TaskRef) ends (returns, crashes or is cancelled), send message(TaskDown) into the channel " +
      "once, without waiting; at once for a task that has ended; past the capacity of a full channel, dropped when " +
      "it is closed or a signal channel; a crash counts as observed only through a Task[R]; VM only."
    ),
    alternatives: [],
  ),
]
