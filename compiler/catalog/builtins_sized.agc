## The conversions between Int and the narrow integer types (Types.NARROW_INTS): to_i on each type, and to_<type>
## and to_<type>! on Int. The VM holds a narrow value as an Int, so to_i changes nothing at run time and the other
## two check the range (vm/numbers.c).

import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = Types.NARROW_INTS.keys.flat_map do |name: String|
  type = Types.NARROW_TYPES[name]
  word = name.downcase
  bounds = Types.NARROW_INTS[name]
  int = [Model.Named(name: "int", type: Types.Type.Int)]
  [
    Model.Builtin(
      name: "#{name}.to_i",
      parameters: [Model.Named(name: word, type: type)],
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
  ]
end
