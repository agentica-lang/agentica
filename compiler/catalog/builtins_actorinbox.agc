import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "ActorInbox.set",
    parameters: [Model.Named(name: "channel", type: Types.Type.Channel(Types.Type.Var("T")))],
    result: Types.Type.Void,
    rule: Model.Rule.ChannelTarget,
    implementation: "ActorInbox.set",
    effects: ["concurrency"],
    description: "Internal to std/actor: keep the channel as the inbox of the running task.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "ActorInbox.get",
    parameters: [],
    result: Types.Type.Optional(Types.Type.Channel(Types.Type.Var("T"))),
    rule: Model.Rule.ActorInbox,
    implementation: "ActorInbox.get",
    effects: ["concurrency"],
    description: "Internal to std/actor: the inbox that ActorInbox.set kept in the running task, if any.",
    alternatives: [],
  ),
]
