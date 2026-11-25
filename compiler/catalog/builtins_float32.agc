## Float32 and its conversions: to_f widens it exactly, to_float32 on Float, Int and each narrow integer type rounds
## once to binary32 (an integer from its 64 bits, not through a Float), and to_bits and from_bits read its 32 bits as a
## UInt32 (vm/numbers.c).

import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Float32.to_f",
    parameters: [Model.Named(name: "float32", type: Types.Type.Float32)],
    result: Types.Type.Float,
    rule: Model.Rule.Plain,
    implementation: "Float32.to_f",
    effects: [],
    description: "The Float32 as a Float, which holds every value exactly.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Float32.to_bits",
    parameters: [Model.Named(name: "float32", type: Types.Type.Float32)],
    result: Types.Type.UInt32,
    rule: Model.Rule.Plain,
    implementation: "Float32.to_bits",
    effects: [],
    description: "The 32 IEEE 754 binary32 bits; every NaN gives 2143289344.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Float32.from_bits",
    parameters: [Model.Named(name: "bits", type: Types.Type.UInt32)],
    result: Types.Type.Float32,
    rule: Model.Rule.Plain,
    implementation: "Float32.from_bits",
    effects: [],
    description: "Read 32 bits as a binary32 Float32; any NaN pattern gives NaN.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Float.to_float32",
    parameters: [Model.Named(name: "float", type: Types.Type.Float)],
    result: Types.Type.Float32,
    rule: Model.Rule.Plain,
    implementation: "Float.to_float32",
    effects: [],
    description: "Round to the nearest Float32, ties to even; past its largest value it is an infinity of that sign.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Int.to_float32",
    parameters: [Model.Named(name: "int", type: Types.Type.Int)],
    result: Types.Type.Float32,
    rule: Model.Rule.Plain,
    implementation: "Int.to_float32",
    effects: [],
    description: "Round the Int to the nearest Float32, ties to even, once.",
    alternatives: [],
  ),
].concat(
  Types.NARROW_INTS.keys.map do |name: String|
    Model.Builtin(
      name: "#{name}.to_float32",
      parameters: [Model.Named(name: name.downcase, type: Types.NARROW_TYPES[name])],
      result: Types.Type.Float32,
      rule: Model.Rule.Plain,
      implementation: "Int.to_float32",
      effects: [],
      description: "Round the #{name} to the nearest Float32, ties to even.",
      alternatives: [],
    )
  end,
)
