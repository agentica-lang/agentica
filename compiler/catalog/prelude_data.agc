## The prelude table, as data: for each catalog row marked Rule.Prelude, the file of its body, the types its variables
## may take and the function that serves each type (docs/future/25-ruby-typed-idioms.md 25.6). The bodies are in
## stdlib/prelude/. Edited by hand; tests/test_stdlib_prelude.py checks that every body exists and that this table and
## the catalog agree.

import Model from "builtin_model"
import Types from "../check/types"

## The builtins that only the prelude may call: the checker does not know them outside a prelude file, and no help or
## suggestion lists them.
export PRELUDE_ONLY = [
  "__fail_arg", "__lazy_channel", "__lazy_chunk_while", "__lazy_count", "__lazy_each", "__lazy_file", "__lazy_find",
  "__lazy_flat_map", "__lazy_group", "__lazy_list", "__lazy_map", "__lazy_produce", "__lazy_range", "__lazy_reduce",
  "__lazy_test", "__lazy_to_a", "__lazy_with_index", "__lazy_write_lines",
]

## Every prelude function, sorted by name.
export ROWS: List[Model.PreludeRow] = [
  Model.PreludeRow(name: "Channel.lazy", module: "lazy", limits: [], selector: "", bodies: {"": "from_channel"}),
  Model.PreludeRow(name: "File.foreach", module: "lazy", limits: [], selector: "", bodies: {"": "from_file"}),
  Model.PreludeRow(name: "Lazy.chunk_while", module: "lazy", limits: [], selector: "", bodies: {"": "chunk_while"}),
  Model.PreludeRow(name: "Lazy.drop", module: "lazy", limits: [], selector: "", bodies: {"": "drop"}),
  Model.PreludeRow(name: "Lazy.drop_while", module: "lazy", limits: [], selector: "", bodies: {"": "drop_while"}),
  Model.PreludeRow(name: "Lazy.each", module: "lazy", limits: [], selector: "", bodies: {"": "each"}),
  Model.PreludeRow(name: "Lazy.each_cons", module: "lazy", limits: [], selector: "", bodies: {"": "each_cons"}),
  Model.PreludeRow(name: "Lazy.each_slice", module: "lazy", limits: [], selector: "", bodies: {"": "each_slice"}),
  Model.PreludeRow(name: "Lazy.filter", module: "lazy", limits: [], selector: "", bodies: {"": "filter"}),
  Model.PreludeRow(name: "Lazy.find", module: "lazy", limits: [], selector: "", bodies: {"": "find"}),
  Model.PreludeRow(name: "Lazy.first", module: "lazy", limits: [], selector: "", bodies: {"": "first"}),
  Model.PreludeRow(name: "Lazy.flat_map", module: "lazy", limits: [], selector: "", bodies: {"": "flat_map"}),
  Model.PreludeRow(name: "Lazy.map", module: "lazy", limits: [], selector: "", bodies: {"": "map"}),
  Model.PreludeRow(name: "Lazy.produce", module: "lazy", limits: [], selector: "", bodies: {"": "produce"}),
  Model.PreludeRow(name: "Lazy.reduce", module: "lazy", limits: [], selector: "", bodies: {"": "reduce"}),
  Model.PreludeRow(name: "Lazy.take", module: "lazy", limits: [], selector: "", bodies: {"": "take"}),
  Model.PreludeRow(name: "Lazy.take_while", module: "lazy", limits: [], selector: "", bodies: {"": "take_while"}),
  Model.PreludeRow(name: "Lazy.to_a", module: "lazy", limits: [], selector: "", bodies: {"": "to_a"}),
  Model.PreludeRow(name: "Lazy.with_index", module: "lazy", limits: [], selector: "", bodies: {"": "with_index"}),
  Model.PreludeRow(name: "Lazy.write_lines", module: "lazy", limits: [], selector: "", bodies: {"": "write_lines"}),
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
  Model.PreludeRow(name: "List.lazy", module: "lazy", limits: [], selector: "", bodies: {"": "from_list"}),
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
  Model.PreludeRow(name: "Range.lazy", module: "lazy", limits: [], selector: "", bodies: {"": "from_range"}),
]
