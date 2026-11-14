import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Zlib.deflate",
    parameters: [
      Model.Named(name: "data", type: Types.Type.Bytes),
      Model.Named(name: "level", type: Types.Type.Int, default: Model.Default.Whole(6)),
      Model.Named(name: "max_bytes", type: Types.Type.Int, default: Model.Default.Whole(1048576)),
    ],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "Zlib.deflate.bytes",
    effects: [],
    description: (
      "Compress bytes to one zlib stream (RFC 1950) at level 0 to 9; empty input is valid; data at most " +
      "1048576 bytes, the output at most max_bytes, 1 to 1048576; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Zlib.inflate",
    parameters: [
      Model.Named(name: "data", type: Types.Type.Bytes),
      Model.Named(name: "max_bytes", type: Types.Type.Int, default: Model.Default.Whole(1048576)),
    ],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "Zlib.inflate.bytes",
    effects: [],
    description: (
      "Decompress one zlib stream (RFC 1950) with its checksum checked; empty input, truncation and any " +
      "trailing byte are errors; data at most 1048576 bytes, the output at most max_bytes, 1 to 1048576; VM " +
      "only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Zlib.gzip",
    parameters: [
      Model.Named(name: "data", type: Types.Type.Bytes),
      Model.Named(name: "level", type: Types.Type.Int, default: Model.Default.Whole(6)),
      Model.Named(name: "max_bytes", type: Types.Type.Int, default: Model.Default.Whole(1048576)),
    ],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "Zlib.gzip.bytes",
    effects: [],
    description: (
      "Compress bytes to one gzip member (RFC 1952) at level 0 to 9; empty input is valid; data at most " +
      "1048576 bytes, the output at most max_bytes, 1 to 1048576; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Zlib.gunzip",
    parameters: [
      Model.Named(name: "data", type: Types.Type.Bytes),
      Model.Named(name: "max_bytes", type: Types.Type.Int, default: Model.Default.Whole(1048576)),
    ],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "Zlib.gunzip.bytes",
    effects: [],
    description: (
      "Decompress one gzip member (RFC 1952) with its CRC and size checked; empty input, truncation and any " +
      "trailing byte (a second member too) are errors; data at most 1048576 bytes, the output at most " +
      "max_bytes, 1 to 1048576; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Zlib.crc32",
    parameters: [
      Model.Named(name: "data", type: Types.Type.Bytes),
      Model.Named(name: "seed", type: Types.Type.Int, default: Model.Default.Whole(0)),
    ],
    result: Types.Type.Result(Types.Type.Int),
    rule: Model.Rule.Plain,
    implementation: "Zlib.crc32.bytes",
    effects: [],
    description: (
      "CRC32 (RFC 1952) of bytes chained after seed (0 when left out): start with no seed, then give each next " +
      "chunk the previous result as its seed; empty input returns the seed unchanged; data at most 1048576 " +
      "bytes, seed 0 to 4294967295; VM only."
    ),
    alternatives: [],
  ),
]
