## The narrow integer types (Types.NARROW_INTS) and their rows: the conversions (to_i on each type, to_<type> and
## to_<type>! on Int), the widenings that always fit, to_f, the bit methods and the wrapping ones. The VM holds a
## narrow value as an Int, so a widening changes nothing at run time, to_<type> checks the range, and the wrapping
## methods keep the low bits of the type (vm/numbers.c). A bit method whose Int form is right on every value of the
## type uses it.

import Types from "../syntax/types"
import Model from "builtin_model"

NARROW_ROWS: List[Model.Builtin] = Types.NARROW_INTS.keys.flat_map do |name: String|
  type = Types.NARROW_TYPES[name]
  word = name.downcase
  bounds = Types.NARROW_INTS[name]
  int = [Model.Named(name: "int", type: Types.Type.Int)]
  same = [Model.Named(name: word, type: type)]
  other = [Model.Named(name: word, type: type), Model.Named(name: "other", type: type)]
  count = [Model.Named(name: word, type: type), Model.Named(name: "count", type: Types.Type.Int)]
  not_from = "Int.bit_not"
  not_text = "Flip every bit; the same as -1 - #{word}."
  right_unsigned_from = "#{name}.shift_right_unsigned"
  if bounds[0] == 0
    not_from = "#{name}.bit_not"
    not_text = "Flip the bits within the width of #{name}: 255 - #{word} for UInt8."
    right_unsigned_from = "Int.shift_right_unsigned"
  end

  wider = Types.NARROW_INTS.keys.select do |target: String|
    limits = Types.NARROW_INTS[target]
    target != name and limits[0] <= bounds[0] and limits[1] >= bounds[1]
  end

  widenings = wider.map do |target: String|
    Model.Builtin(
      name: "#{name}.to_#{target.downcase}",
      parameters: same,
      result: Types.NARROW_TYPES[target],
      rule: Model.Rule.Plain,
      implementation: "Int.from_narrow",
      effects: [],
      description: "The #{name} as a #{target}; every #{name} value fits.",
      alternatives: [],
    )
  end

  [
    Model.Builtin(
      name: "#{name}.to_i",
      parameters: same,
      result: Types.Type.Int,
      rule: Model.Rule.Plain,
      implementation: "Int.from_narrow",
      effects: [],
      description: "The #{name} as an Int.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Int.to_#{word}",
      parameters: int,
      result: Types.Type.Result(type),
      rule: Model.Rule.Plain,
      implementation: "Int.to_#{word}",
      effects: [],
      description: "The Int as a #{name}, or an error when it is outside #{bounds[0]} to #{bounds[1]}.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Int.to_#{word}!",
      parameters: int,
      result: type,
      rule: Model.Rule.Plain,
      implementation: "Int.to_#{word}!",
      effects: [],
      description: "The Int as a #{name}; halts when it is outside #{bounds[0]} to #{bounds[1]}.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "Int.wrap_#{word}",
      parameters: int,
      result: type,
      rule: Model.Rule.Plain,
      implementation: "Int.wrap_#{word}",
      effects: [],
      description: "The low bits of the Int as a #{name}, in #{bounds[0]} to #{bounds[1]}; it never fails.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "#{name}.to_f",
      parameters: same,
      result: Types.Type.Float,
      rule: Model.Rule.Plain,
      implementation: "Float.from_int",
      effects: [],
      description: "The #{name} as a Float, which holds every value.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "#{name}.bit_and",
      parameters: other,
      result: type,
      rule: Model.Rule.Plain,
      implementation: "Int.bit_and",
      effects: [],
      description: "Bitwise and.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "#{name}.bit_or",
      parameters: other,
      result: type,
      rule: Model.Rule.Plain,
      implementation: "Int.bit_or",
      effects: [],
      description: "Bitwise or.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "#{name}.bit_xor",
      parameters: other,
      result: type,
      rule: Model.Rule.Plain,
      implementation: "Int.bit_xor",
      effects: [],
      description: "Bitwise exclusive or.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "#{name}.bit_not",
      parameters: same,
      result: type,
      rule: Model.Rule.Plain,
      implementation: not_from,
      effects: [],
      description: not_text,
      alternatives: [],
    ),
    Model.Builtin(
      name: "#{name}.shift_left",
      parameters: count,
      result: type,
      rule: Model.Rule.Plain,
      implementation: "#{name}.shift_left",
      effects: [],
      description: (
        "Shift bits left; bits that leave the width of #{name} are dropped, so it wraps; a count of the width " +
        "or more gives 0; a negative count halts."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "#{name}.shift_right",
      parameters: count,
      result: type,
      rule: Model.Rule.Plain,
      implementation: "Int.shift_right",
      effects: [],
      description: "Shift bits right; a signed type copies its sign bit; a negative count halts.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "#{name}.shift_right_unsigned",
      parameters: count,
      result: type,
      rule: Model.Rule.Plain,
      implementation: right_unsigned_from,
      effects: [],
      description: (
        "Shift the bits of the width of #{name} right, filling with zeros; a count of the width or more gives 0; " +
        "a negative count halts."
      ),
      alternatives: [],
    ),
    Model.Builtin(
      name: "#{name}.wrapping_add",
      parameters: other,
      result: type,
      rule: Model.Rule.Plain,
      implementation: "#{name}.wrapping_add",
      effects: [],
      description: "The sum, keeping the low bits of #{name}.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "#{name}.wrapping_sub",
      parameters: other,
      result: type,
      rule: Model.Rule.Plain,
      implementation: "#{name}.wrapping_sub",
      effects: [],
      description: "The difference, keeping the low bits of #{name}.",
      alternatives: [],
    ),
    Model.Builtin(
      name: "#{name}.wrapping_mul",
      parameters: other,
      result: type,
      rule: Model.Rule.Plain,
      implementation: "#{name}.wrapping_mul",
      effects: [],
      description: "The product, keeping the low bits of #{name}.",
      alternatives: [],
    ),
  ].concat(widenings)
end

ROWS: List[Model.Builtin] = NARROW_ROWS.concat([
  Model.Builtin(
    name: "Int.wrapping_add",
    parameters: [Model.Named(name: "int", type: Types.Type.Int), Model.Named(name: "other", type: Types.Type.Int)],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "Int.wrapping_add",
    effects: [],
    description: "The sum, keeping the low 64 bits.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Int.wrapping_sub",
    parameters: [Model.Named(name: "int", type: Types.Type.Int), Model.Named(name: "other", type: Types.Type.Int)],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "Int.wrapping_sub",
    effects: [],
    description: "The difference, keeping the low 64 bits.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Int.wrapping_mul",
    parameters: [Model.Named(name: "int", type: Types.Type.Int), Model.Named(name: "other", type: Types.Type.Int)],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "Int.wrapping_mul",
    effects: [],
    description: "The product, keeping the low 64 bits.",
    alternatives: [],
  ),
])
