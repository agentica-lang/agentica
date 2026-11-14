import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Channel.address",
    parameters: [Model.Named(name: "channel", type: Types.Type.Channel(Types.Type.Var("T")))],
    result: Types.Type.Address(Types.Type.Var("T")),
    rule: Model.Rule.ChannelAddress,
    implementation: "Channel.address",
    effects: [],
    description: "A send-only reference to the channel, which is data and does not keep the channel alive; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Channel.close",
    parameters: [Model.Named(name: "channel", type: Types.Type.Channel(Types.Type.Var("T")))],
    result: Types.Type.Void,
    rule: Model.Rule.ChannelTarget,
    implementation: "Channel.close",
    effects: ["concurrency"],
    description: "Close a channel idempotently; waiting tasks wake, and received values still drain; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Channel.closed?",
    parameters: [Model.Named(name: "channel", type: Types.Type.Channel(Types.Type.Var("T")))],
    result: Types.Type.Bool,
    rule: Model.Rule.ChannelTarget,
    implementation: "Channel.closed?",
    effects: [],
    description: "True once the channel is closed, even with values still buffered; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Channel.empty?",
    parameters: [Model.Named(name: "channel", type: Types.Type.Channel(Types.Type.Var("T")))],
    result: Types.Type.Bool,
    rule: Model.Rule.ChannelTarget,
    implementation: "Channel.empty?",
    effects: [],
    description: "True when no value is left to receive; after closed?, it says the channel is drained; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Channel.lazy",
    parameters: [
      Model.Named(name: "channel", type: Types.Type.Channel(Types.Type.Var("A"))),
      Model.Named(name: "timeout_ms", type: Types.Type.Int),
    ],
    result: Types.Type.Lazy(Types.Type.Var("A")),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: (
      "Source: the values of the channel until it is closed and drained; each wait for a value obeys timeout_ms, " +
      "and a timeout ends the terminal with error(\"channel: timed out\"); VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Channel.new",
    parameters: [Model.Named(name: "capacity", type: Types.Type.Int)],
    result: Types.Type.Channel(Types.Type.Var("T")),
    rule: Model.Rule.ChannelNew,
    implementation: "Channel.new",
    effects: [],
    description: "Create a channel that holds 1 to 1048576 values; needs an expected Channel[T] type; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Channel.recv",
    parameters: [
      Model.Named(name: "channel", type: Types.Type.Channel(Types.Type.Var("T"))),
      Model.Named(name: "timeout_ms", type: Types.Type.Int),
    ],
    result: Types.Type.Result(Types.Type.Var("T")),
    rule: Model.Rule.ChannelRecv,
    implementation: "Channel.recv",
    effects: ["concurrency"],
    description: (
      "Take the oldest value; wait up to timeout_ms; error(\"channel: closed\") once closed and empty, " +
      "error(\"channel: timed out\"); VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Channel.send",
    parameters: [
      Model.Named(name: "channel", type: Types.Type.Channel(Types.Type.Var("T"))),
      Model.Named(name: "value", type: Types.Type.Var("T")),
      Model.Named(name: "timeout_ms", type: Types.Type.Int),
    ],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.ChannelSend,
    implementation: "Channel.send",
    effects: ["concurrency"],
    description: (
      "Add a value in order; wait for room up to timeout_ms; error(\"channel: closed\") or error(\"channel: timed " +
      "out\"); VM only."
    ),
    alternatives: [],
  ),
]
