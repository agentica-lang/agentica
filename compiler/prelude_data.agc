## The prelude table, as data: for each catalog row marked Rule.Prelude, the file of its body, the types its variables
## may take and the function that serves each type (docs/future/25-ruby-typed-idioms.md 25.6). The bodies are in
## stdlib/prelude/. Edited by hand; tests/test_stdlib_prelude.py checks that every body exists and that this table and
## the catalog agree.

import Model from "builtin_model"
import Types from "types"

## The builtins that only the prelude may call: the checker does not know them outside a prelude file, and no help or
## suggestion lists them.
export PRELUDE_ONLY = [
  "__fail_arg", "__stream_each", "__stream_filter", "__stream_iterate", "__stream_map", "__stream_reduce",
  "__stream_take", "__stream_take_while", "__stream_to_list",
]

## Every prelude function, sorted by name.
export ROWS: List[Model.PreludeRow] = [
  Model.PreludeRow(name: "Stream.each", module: "stream", limits: [], selector: "", bodies: {"": "each"}),
  Model.PreludeRow(name: "Stream.filter", module: "stream", limits: [], selector: "", bodies: {"": "filter"}),
  Model.PreludeRow(name: "Stream.iterate", module: "stream", limits: [], selector: "", bodies: {"": "iterate"}),
  Model.PreludeRow(name: "Stream.map", module: "stream", limits: [], selector: "", bodies: {"": "map"}),
  Model.PreludeRow(name: "Stream.reduce", module: "stream", limits: [], selector: "", bodies: {"": "reduce"}),
  Model.PreludeRow(name: "Stream.take", module: "stream", limits: [], selector: "", bodies: {"": "take"}),
  Model.PreludeRow(
    name: "Stream.take_while", module: "stream", limits: [], selector: "", bodies: {"": "take_while"},
  ),
  Model.PreludeRow(name: "Stream.to_list", module: "stream", limits: [], selector: "", bodies: {"": "to_list"}),
  Model.PreludeRow(name: "List.drop_while", module: "list", limits: [], selector: "", bodies: {"": "drop_while"}),
  Model.PreludeRow(name: "List.each_slice", module: "list", limits: [], selector: "", bodies: {"": "each_slice"}),
  Model.PreludeRow(
    name: "List.each_with_index", module: "list", limits: [], selector: "", bodies: {"": "each_with_index"},
  ),
  Model.PreludeRow(name: "List.find", module: "list", limits: [], selector: "", bodies: {"": "find"}),
  Model.PreludeRow(name: "List.flat_map", module: "list", limits: [], selector: "", bodies: {"": "flat_map"}),
  Model.PreludeRow(
    name: "List.group_by",
    module: "list",
    limits: [Model.Limit(variable: "K", allowed: [Types.Type.Int, Types.Type.String], what: "a key")],
    selector: "",
    bodies: {"": "group_by"},
  ),
  Model.PreludeRow(
    name: "List.max_by",
    module: "list",
    limits: [
      Model.Limit(
        variable: "O", allowed: [Types.Type.Int, Types.Type.Float, Types.Type.String], what: "a key",
      ),
    ],
    selector: "O",
    bodies: {"Int": "max_by_int", "Float": "max_by_float", "String": "max_by_string"},
  ),
  Model.PreludeRow(
    name: "List.min_by",
    module: "list",
    limits: [
      Model.Limit(
        variable: "O", allowed: [Types.Type.Int, Types.Type.Float, Types.Type.String], what: "a key",
      ),
    ],
    selector: "O",
    bodies: {"Int": "min_by_int", "Float": "min_by_float", "String": "min_by_string"},
  ),
  Model.PreludeRow(name: "List.partition", module: "list", limits: [], selector: "", bodies: {"": "partition"}),
  Model.PreludeRow(
    name: "List.sum",
    module: "list",
    limits: [Model.Limit(variable: "N", allowed: [Types.Type.Int, Types.Type.Float], what: "numbers")],
    selector: "N",
    bodies: {"Int": "sum_int", "Float": "sum_float"},
  ),
  Model.PreludeRow(name: "List.take_while", module: "list", limits: [], selector: "", bodies: {"": "take_while"}),
  Model.PreludeRow(
    name: "List.tally",
    module: "list",
    limits: [Model.Limit(variable: "K", allowed: [Types.Type.Int, Types.Type.String], what: "items")],
    selector: "",
    bodies: {"": "tally"},
  ),
  Model.PreludeRow(
    name: "List.uniq",
    module: "list",
    limits: [Model.Limit(variable: "K", allowed: [Types.Type.Int, Types.Type.String], what: "items")],
    selector: "",
    bodies: {"": "uniq"},
  ),
  Model.PreludeRow(name: "Map.each", module: "map", limits: [], selector: "", bodies: {"": "each"}),
  Model.PreludeRow(name: "Map.filter", module: "map", limits: [], selector: "", bodies: {"": "filter"}),
]
