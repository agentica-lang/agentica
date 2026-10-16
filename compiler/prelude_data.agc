## The prelude table, as data: for each catalog row marked Rule.Prelude, the file of its body, the types its variables
## may take and the function that serves each type (docs/future/25-ruby-typed-idioms.md 25.6). The bodies are in
## stdlib/prelude/. Edited by hand; tests/test_stdlib_prelude.py checks that every body exists and that this table and
## the catalog agree.

import Model from "builtin_model"
import Types from "types"

## The builtins that only the prelude may call: the checker does not know them outside a prelude file, and no help or
## suggestion lists them.
export def prelude_only() -> List[String]
  return ["__fail_arg"]
end

## Every prelude function, sorted by name.
export def rows() -> List[Model.PreludeRow]
  keys = [Types.Type.Int, Types.Type.String]
  numbers = [Types.Type.Int, Types.Type.Float]
  orders = [Types.Type.Int, Types.Type.Float, Types.Type.String]
  return [
    plain("List.drop_while", "list", "drop_while"),
    plain("List.each_slice", "list", "each_slice"),
    plain("List.each_with_index", "list", "each_with_index"),
    plain("List.find", "list", "find"),
    plain("List.flat_map", "list", "flat_map"),
    limited("List.group_by", "list", "group_by", "K", keys, "a key"),
    chosen("List.max_by", "list", "O", orders, "a key", ["max_by_int", "max_by_float", "max_by_string"]),
    chosen("List.min_by", "list", "O", orders, "a key", ["min_by_int", "min_by_float", "min_by_string"]),
    plain("List.partition", "list", "partition"),
    chosen("List.sum", "list", "N", numbers, "numbers", ["sum_int", "sum_float"]),
    plain("List.take_while", "list", "take_while"),
    limited("List.tally", "list", "tally", "K", keys, "items"),
    limited("List.uniq", "list", "uniq", "K", keys, "items"),
    plain("Map.each", "map", "each"),
    plain("Map.filter", "map", "filter"),
  ]
end

# A function whose variables take any type, and the one function that serves them all.
def plain(name: String, module: String, function: String) -> Model.PreludeRow
  return Model.PreludeRow(name: name, module: module, limits: [], selector: "", bodies: {"": function})
end

# One function for every allowed type of one limited variable.
def limited(
  name: String, module: String, function: String, variable: String, allowed: List[Types.Type], what: String
) -> Model.PreludeRow
  limit = Model.Limit(variable: variable, allowed: allowed, what: what)
  return Model.PreludeRow(name: name, module: module, limits: [limit], selector: "", bodies: {"": function})
end

# One function for each allowed type of the limited variable: the type of the variable picks the body.
def chosen(
  name: String, module: String, variable: String, allowed: List[Types.Type], what: String, functions: List[String]
) -> Model.PreludeRow
  limit = Model.Limit(variable: variable, allowed: allowed, what: what)
  bodies: Map[String, String] = {}
  index = 0
  for type in allowed
    bodies = bodies.put(Types.tag(type), functions[index])
    index += 1
  end
  return Model.PreludeRow(name: name, module: module, limits: [limit], selector: variable, bodies: bodies)
end
