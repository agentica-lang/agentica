## The text form of the builtin catalog, for tests. See catalog_text. tests/frontend-catalog-common.rkt prints the same
## text from src/builtins.rkt.

import Ast from "ast"
import Model from "builtin_model"
import Builtins from "builtins"
import Suggest from "suggest"
import Text from "text"
import Types from "types"

## The whole catalog, one line per fact, then the answer to each probe. A probe is `near:WORD` (the did-you-mean help
## among the public builtin names), `ref:NAME/ARITY` (the form of NAME with that many arguments), `std:NAME` (is NAME
## inside a std-only module) `type:WORD` (the help for an unknown type: the record and enum names, and the primitive
## and handle type names), `sig:NAME` (the signature of every form of NAME) or `disp:NAME` (display_name of a linked
## name).
export def catalog_text(probes: List[String]) -> String
  catalog = Builtins.catalog()
  lines: List[String] = []
  for name in catalog.entries.keys
    lines = lines.concat(builtin_lines(catalog.entries[name]))
  end
  lines = lines.concat(record_lines(catalog)).concat(enum_lines(catalog)).concat(name_lines(catalog))
  for probe in probes
    lines = lines.push(probe_line(catalog, probe))
  end
  return lines.join("\n")
end

def builtin_lines(entry: Model.Builtin) -> List[String]
  forms = [entry].concat(entry.alternatives)
  lines: List[String] = ["builtin #{entry.name} forms=#{forms.size}"]
  for form in forms
    lines = lines.push("  #{form_line(form)}")
  end
  return lines
end

def form_line(form: Model.Builtin) -> String
  return (
    "#{Builtins.form_signature(form)} shape=#{shape_text(form)} rule=#{rule_name(form.rule)} " +
    "impl=#{Text.quote(form.implementation)} effects=#{quoted_list(form.effects)} " +
    "desc=#{Text.quote(form.description)}"
  )
end

# The parameter and result types with their variants written out, because to_text prints Struct("X"), Enum("X", []) and
# Var("X") alike.
def shape_text(form: Model.Builtin) -> String
  parameters = form.parameters.map do |parameter: Model.Named| Types.debug_text(parameter.type) end
  return "(#{parameters.join(", ")}) -> #{Types.debug_text(form.result)}"
end

def record_lines(catalog: Builtins.Catalog) -> List[String]
  lines: List[String] = []
  for name in catalog.records.keys.sort
    fields = catalog.records[name].map do |field: Model.Named| "#{field.name}: #{Types.debug_text(field.type)}" end
    lines = lines.push("record #{name} #{fields.join(", ")}")
  end
  return lines
end

def enum_lines(catalog: Builtins.Catalog) -> List[String]
  lines: List[String] = []
  for name in catalog.enums.keys.sort
    definition = catalog.enums[name]
    variants = definition.variants.map do |variant: Model.Variant| variant_text(variant) end
    lines = lines.push(
      "enum #{name} parameters=#{quoted_list(definition.parameters)} variants=#{variants.join(" | ")}",
    )
  end
  return lines
end

def name_lines(catalog: Builtins.Catalog) -> List[String]
  std_only: List[String] = []
  for name in catalog.std_only.keys.sort
    std_only = std_only.push("#{name}=#{catalog.std_only[name].std_path} as #{catalog.std_only[name].alias}")
  end
  return [
    "public #{quoted_list(catalog.public_names)}",
    "bare #{quoted_list(catalog.bare_names.to_a.sort)}",
    "opaque #{quoted_list(catalog.opaque.to_a.sort)}",
    "handles #{quoted_list(catalog.handles.to_a.sort)}",
    "reserved #{quoted_list(catalog.reserved.to_a.sort)}",
    "std-only #{std_only.join(", ")}",
  ]
end

def probe_line(catalog: Builtins.Catalog, probe: String) -> String
  colon = probe.index_of(":").unwrap!
  kind = probe.slice(0, colon)
  rest = probe.slice(colon + 1, probe.length - colon - 1)
  if kind == "near"
    near = Suggest.did_you_mean_among(rest, catalog.public_names, [])
    return "#{probe} -> #{help_text(near)}"
  elsif kind == "ref"
    return "#{probe} -> #{ref_text(catalog, rest)}"
  elsif kind == "type"
    return "#{probe} -> #{help_text(type_help(catalog, rest))}"
  elsif kind == "sig"
    return "#{probe} -> #{signature_text(catalog, rest)}"
  elsif kind == "disp"
    return "#{probe} -> #{Text.quote(Types.display_name(rest))}"
  end
  return "#{probe} -> #{Builtins.std_only_name?(catalog, rest)}"
end

def type_help(catalog: Builtins.Catalog, word: String) -> Ast.Optional[String]
  shared = [
    "Int",
    "Float",
    "Bool",
    "String",
    "Nil",
    "Void",
    "List",
    "Map",
    "Set",
    "Result",
    "Json",
    "Fn",
    "Task",
    "Channel",
    "Range",
  ].concat(catalog.opaque.to_a)
  return Suggest.did_you_mean_among(word, catalog.records.keys.concat(catalog.enums.keys), shared)
end

def signature_text(catalog: Builtins.Catalog, name: String) -> String
  found = Builtins.lookup(catalog, name)
  if found.ok?
    return Text.quote(Builtins.signature(found.unwrap!))
  end
  return "-"
end

def ref_text(catalog: Builtins.Catalog, spec: String) -> String
  parts = spec.split("/")
  found = Builtins.ref(catalog, parts[0], parts[1].to_i!)
  if found.ok?
    return form_line(found.unwrap!)
  end
  return "-"
end

def help_text(help: Ast.Optional[String]) -> String
  case help
    Ast.Optional.Present(text) -> return Text.quote(text)
    Ast.Optional.Absent -> return "-"
  end
end

def variant_text(variant: Model.Variant) -> String
  if variant.payload.size == 0
    return variant.name
  end
  payload = variant.payload.map do |type: Types.Type| Types.debug_text(type) end.join(", ")
  return "#{variant.name}(#{payload})"
end

def quoted_list(items: List[String]) -> String
  quoted = items.map do |item: String| Text.quote(item) end.join(", ")
  return "[#{quoted}]"
end

def rule_name(rule: Model.Rule) -> String
  case rule
    Model.Rule.Plain -> return "Plain"
    Model.Rule.ChannelNew -> return "ChannelNew"
    Model.Rule.ChannelRecv -> return "ChannelRecv"
    Model.Rule.ChannelSend -> return "ChannelSend"
    Model.Rule.ChannelTarget -> return "ChannelTarget"
    Model.Rule.Error -> return "Error"
    Model.Rule.Identity -> return "Identity"
    Model.Rule.JsonDecode -> return "JsonDecode"
    Model.Rule.JsonEncode -> return "JsonEncode"
    Model.Rule.JsonFrom -> return "JsonFrom"
    Model.Rule.JsonSchema -> return "JsonSchema"
    Model.Rule.ListAll -> return "ListAll"
    Model.Rule.ListAny -> return "ListAny"
    Model.Rule.ListAppend -> return "ListAppend"
    Model.Rule.ListAt -> return "ListAt"
    Model.Rule.ListConcat -> return "ListConcat"
    Model.Rule.ListCount -> return "ListCount"
    Model.Rule.ListEach -> return "ListEach"
    Model.Rule.ListFilter -> return "ListFilter"
    Model.Rule.ListMap -> return "ListMap"
    Model.Rule.ListReduce -> return "ListReduce"
    Model.Rule.ListRepeat -> return "ListRepeat"
    Model.Rule.ListReverse -> return "ListReverse"
    Model.Rule.ListSet -> return "ListSet"
    Model.Rule.ListSize -> return "ListSize"
    Model.Rule.ListSort -> return "ListSort"
    Model.Rule.ListSortBy -> return "ListSortBy"
    _ -> return later_rule_name(rule)
  end
end

def later_rule_name(rule: Model.Rule) -> String
  case rule
    Model.Rule.MapDelete -> return "MapDelete"
    Model.Rule.MapGet -> return "MapGet"
    Model.Rule.MapGetDefault -> return "MapGetDefault"
    Model.Rule.MapHas -> return "MapHas"
    Model.Rule.MapKeys -> return "MapKeys"
    Model.Rule.MapPut -> return "MapPut"
    Model.Rule.MapSize -> return "MapSize"
    Model.Rule.MapValues -> return "MapValues"
    Model.Rule.Ok -> return "Ok"
    Model.Rule.OkVoid -> return "OkVoid"
    Model.Rule.ResultDefault -> return "ResultDefault"
    Model.Rule.ResultMessage -> return "ResultMessage"
    Model.Rule.ResultOk -> return "ResultOk"
    Model.Rule.ResultUnwrap -> return "ResultUnwrap"
    Model.Rule.SetAdd -> return "SetAdd"
    Model.Rule.SetCombine -> return "SetCombine"
    Model.Rule.SetInclude -> return "SetInclude"
    Model.Rule.SetNew -> return "SetNew"
    Model.Rule.SetQuery -> return "SetQuery"
    Model.Rule.SetSubset -> return "SetSubset"
    Model.Rule.SetToA -> return "SetToA"
    Model.Rule.Show -> return "Show"
    Model.Rule.TaskAwait -> return "TaskAwait"
    Model.Rule.TaskAwaitTimeout -> return "TaskAwaitTimeout"
    Model.Rule.TaskSpawn -> return "TaskSpawn"
    Model.Rule.TaskSpawnOwning -> return "TaskSpawnOwning"
    Model.Rule.TestEq -> return "TestEq"
    Model.Rule.TestResult -> return "TestResult"
    _ -> return "?"
  end
end
