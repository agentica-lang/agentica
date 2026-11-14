import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Lazy.chunk_while",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
      Model.Named(name: "block", type: Types.Type.Fn([Types.Type.Var("A"), Types.Type.Var("A")], Types.Type.Bool)),
    ],
    result: Types.Type.Lazy(Types.Type.List(Types.Type.Var("A"))),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Lazy step: group runs of items, a new group where block(previous, item) is false.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.deflate",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Bytes)),
      Model.Named(name: "level", type: Types.Type.Int, default: Model.Default.Whole(6)),
      Model.Named(name: "raw", type: Types.Type.Bool, default: Model.Default.Flag(false)),
    ],
    result: Types.Type.Lazy(Types.Type.Bytes),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: (
      "Lazy step: compress byte chunks of any size to one zlib stream (RFC 1950), or raw deflate (RFC 1951) " +
      "when raw is true, at level 0 to 9; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.drop",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
      Model.Named(name: "count", type: Types.Type.Int),
    ],
    result: Types.Type.Lazy(Types.Type.Var("A")),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Lazy step: skip the first count items; negative counts halt.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.drop_while",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
      Model.Named(name: "block", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Bool)),
    ],
    result: Types.Type.Lazy(Types.Type.Var("A")),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Lazy step: skip items while block is true, then keep the rest.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.each",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
      Model.Named(name: "block", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Result(Types.Type.Void))),
    ],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: (
      "Terminal: call block on each item in order; stops at the first error block returns, which is the result."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.each_cons",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
      Model.Named(name: "size", type: Types.Type.Int),
    ],
    result: Types.Type.Lazy(Types.Type.List(Types.Type.Var("A"))),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Lazy step: each window of size consecutive items; size below 1 halts.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.each_slice",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
      Model.Named(name: "size", type: Types.Type.Int),
    ],
    result: Types.Type.Lazy(Types.Type.List(Types.Type.Var("A"))),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Lazy step: slices of size items, the last one shorter; size below 1 halts.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.filter",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
      Model.Named(name: "block", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Bool)),
    ],
    result: Types.Type.Lazy(Types.Type.Var("A")),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Lazy step: keep the items whose predicate is true.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.find",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
      Model.Named(name: "block", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Bool)),
    ],
    result: Types.Type.Result(Types.Type.Var("A")),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Terminal: the first item block accepts, else error(\"not found\") when the source ends.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.first",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
      Model.Named(name: "count", type: Types.Type.Int),
    ],
    result: Types.Type.Result(Types.Type.List(Types.Type.Var("A"))),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Terminal: the first count items (fewer if the source ends); negative counts halt.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.flat_map",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
      Model.Named(name: "block", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.List(Types.Type.Var("B")))),
    ],
    result: Types.Type.Lazy(Types.Type.Var("B")),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Lazy step: the items of the lists block returns, in order.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.gunzip",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Bytes)),
      Model.Named(name: "max_bytes", type: Types.Type.Int, default: Model.Default.Whole(1073741824)),
    ],
    result: Types.Type.Lazy(Types.Type.Bytes),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: (
      "Lazy step: decompress byte chunks of one gzip member (RFC 1952) with its CRC and size checked; " +
      "truncation, any trailing byte (a second member too) and output past max_bytes end the run with an " +
      "error; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.gzip",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Bytes)),
      Model.Named(name: "level", type: Types.Type.Int, default: Model.Default.Whole(6)),
    ],
    result: Types.Type.Lazy(Types.Type.Bytes),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Lazy step: compress byte chunks of any size to one gzip member (RFC 1952), level 0 to 9; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.inflate",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Bytes)),
      Model.Named(name: "raw", type: Types.Type.Bool, default: Model.Default.Flag(false)),
      Model.Named(name: "max_bytes", type: Types.Type.Int, default: Model.Default.Whole(1073741824)),
    ],
    result: Types.Type.Lazy(Types.Type.Bytes),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: (
      "Lazy step: decompress byte chunks of one zlib stream (RFC 1950), or raw deflate (RFC 1951) when raw " +
      "is true, with its checksum checked; truncation, any trailing byte and output past max_bytes end the " +
      "run with an error; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.map",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
      Model.Named(name: "block", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Var("B"))),
    ],
    result: Types.Type.Lazy(Types.Type.Var("B")),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Lazy step: block applied to each item.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.produce",
    parameters: [
      Model.Named(name: "seed", type: Types.Type.Var("A")),
      Model.Named(name: "block", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Var("A"))),
    ],
    result: Types.Type.Lazy(Types.Type.Var("A")),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: (
      "Endless source: seed, block(seed), block(block(seed)) ...; end it with take, take_while, first or find."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.reduce",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
      Model.Named(name: "initial", type: Types.Type.Var("B")),
      Model.Named(name: "block", type: Types.Type.Fn([Types.Type.Var("B"), Types.Type.Var("A")], Types.Type.Var("B"))),
    ],
    result: Types.Type.Result(Types.Type.Var("B")),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Terminal: fold left from initial in order.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.take",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
      Model.Named(name: "count", type: Types.Type.Int),
    ],
    result: Types.Type.Lazy(Types.Type.Var("A")),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Lazy step: at most count items, then the source stops; negative counts halt.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.take_while",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
      Model.Named(name: "block", type: Types.Type.Fn([Types.Type.Var("A")], Types.Type.Bool)),
    ],
    result: Types.Type.Lazy(Types.Type.Var("A")),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Lazy step: items while block is true; stops at the first false.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.to_a",
    parameters: [Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A")))],
    result: Types.Type.Result(Types.Type.List(Types.Type.Var("A"))),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Terminal: every item in a list; never ends on an endless source.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.with_index",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Var("A"))),
      Model.Named(name: "block", type: Types.Type.Fn([Types.Type.Var("A"), Types.Type.Int], Types.Type.Var("B"))),
    ],
    result: Types.Type.Lazy(Types.Type.Var("B")),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: [],
    description: "Lazy step: block(item, index) for each item, the index from 0.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.write_bytes",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.Bytes)),
      Model.Named(name: "path", type: Types.Type.String),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
    ],
    result: Types.Type.Result(Types.Type.Int),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: ["filesystem"],
    description: (
      "Terminal: write each byte chunk to a file, created or truncated, and return the bytes written; the " +
      "file opens before the first item is pulled and is flushed and closed before the terminal returns; VM " +
      "only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Lazy.write_lines",
    parameters: [
      Model.Named(name: "lazy", type: Types.Type.Lazy(Types.Type.String)),
      Model.Named(name: "path", type: Types.Type.String),
      Model.Named(name: "timeout_ms", type: Types.Type.Int, default: Model.Default.Whole(30000)),
    ],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.Prelude,
    implementation: "",
    effects: ["filesystem"],
    description: (
      "Terminal: write each item and a line feed to a file, created or truncated; the file opens before the first " +
      "item is pulled and is flushed and closed before the terminal returns; VM only."
    ),
    alternatives: [],
  ),
]
