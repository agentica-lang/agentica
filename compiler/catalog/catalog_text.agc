## The text form of the builtin catalog, for tests. See catalog_text. The golden is
## tests/fixtures/frontend/catalog/catalog.text.

import Ast from "../syntax/ast"
import Suggest from "../syntax/suggest"
import Text from "../syntax/text"
import Types from "../syntax/types"
import Model from "builtin_model"
import Builtins from "builtins"
import {
  BARE_NAMES, CALLABLE_NAMES, ENTRIES, ENUMS, HANDLES, OPAQUE_TYPES, PRELUDE,
  PRELUDE_ONLY, PUBLIC_NAMES, RECORDS, RESERVED, STD_ONLY,
} from "builtins"

## The whole catalog, one line per fact, then the answer to each probe. A probe is `near:WORD` (the did-you-mean help
## among the builtin names a call can name), `ref:NAME/ARITY` (the form of NAME with that many arguments), `std:NAME`
## (is NAME inside a std-only module) `type:WORD` (the help for an unknown type: the record and enum names, and the
## primitive and handle type names), `sig:NAME` (the signature of every form of NAME) or `disp:NAME` (display_name of a
## linked name).
export def catalog_text(probes: List[String]) -> String
  lines: List[String] = []
  for name in ENTRIES.keys
    lines = lines.concat(builtin_lines(ENTRIES[name]))
  end

  lines = lines.concat(record_lines()).concat(enum_lines()).concat(name_lines())
  for probe in probes
    lines = lines.push(probe_line(probe))
  end

  return lines.join("\n")
end

def builtin_lines(entry: Model.Builtin) -> List[String]
  forms = [entry].concat(entry.alternatives)
  lines: List[String] = ["builtin #{entry.name} forms=#{forms.size}"]
  for form in forms
    lines = lines.push("  #{form_line(form)}")
  end

  problem = Builtins.default_problem(entry)
  if problem != ""
    lines = lines.push("  default-problem #{Text.quote(problem)}")
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
  parameters = form.parameters.map do |parameter: Model.Named| shape_parameter(parameter) end
  return "(#{parameters.join(", ")}) -> #{Types.debug_text(form.result)}"
end

# A parameter type, then ` = default` when it has one.
def shape_parameter(parameter: Model.Named) -> String
  written = Types.debug_text(parameter.type)
  if Builtins.default_present?(parameter.default)
    return "#{written} = #{Builtins.default_text(parameter.default)}"
  end

  return written
end

def record_lines() -> List[String]
  lines: List[String] = []
  for name in RECORDS.keys.sort
    fields = RECORDS[name].map do |field: Model.Named| "#{field.name}: #{Types.debug_text(field.type)}" end
    lines = lines.push("record #{name} #{fields.join(", ")}")
  end

  return lines
end

def enum_lines() -> List[String]
  lines: List[String] = []
  for name in ENUMS.keys.sort
    definition = ENUMS[name]
    variants = definition.variants.map do |variant: Model.Variant| variant_text(variant) end
    lines = lines.push(
      "enum #{name} parameters=#{quoted_list(definition.parameters)} variants=#{variants.join(" | ")}",
    )
  end

  return lines
end

def name_lines() -> List[String]
  std_only: List[String] = []
  for name in STD_ONLY.keys.sort
    std_only = std_only.push("#{name}=#{STD_ONLY[name][0]} as #{STD_ONLY[name][1]}")
  end

  rows: List[String] = []
  for name in PRELUDE.keys.sort
    row = PRELUDE[name]
    types = row.limits.map do |limit: Model.Limit| "#{limit.variable} in #{limit_types(limit)}" end
    bodies = row.bodies.keys.sort.map do |type: String| "#{type}=#{row.bodies[type]}" end
    rows = rows.push("#{name}=#{row.module} limits=#{quoted_list(types)} bodies=#{quoted_list(bodies)}")
  end

  return [
    "public #{quoted_list(PUBLIC_NAMES)}",
    "bare #{quoted_list(BARE_NAMES.to_a.sort)}",
    "opaque #{quoted_list(OPAQUE_TYPES.to_a.sort)}",
    "handles #{quoted_list(HANDLES.to_a.sort)}",
    "reserved #{quoted_list(RESERVED.to_a.sort)}",
    "std-only #{std_only.join(", ")}",
    "prelude-only #{quoted_list(PRELUDE_ONLY.to_a.sort)}",
    "prelude #{rows.join(", ")}",
  ]
end

def limit_types(limit: Model.Limit) -> String
  return limit.allowed.map do |type: Types.Type| Types.debug_text(type) end.join("/")
end

def probe_line(probe: String) -> String
  colon = probe.index_of(":").unwrap!
  kind = probe.slice(0, colon)
  rest = probe.slice(colon + 1, probe.length - colon - 1)
  case kind
    "near" ->
      near = Suggest.did_you_mean_among(rest, CALLABLE_NAMES, [])
      return "#{probe} -> #{help_text(near)}"
    "ref" -> return "#{probe} -> #{ref_text(rest)}"
    "type" -> return "#{probe} -> #{help_text(type_help(rest))}"
    "sig" -> return "#{probe} -> #{signature_text(rest)}"
    "disp" -> return "#{probe} -> #{Text.quote(Types.display_name(rest))}"
    _ -> return "#{probe} -> #{Builtins.std_only_name?(rest)}"
  end
end

def type_help(word: String) -> Optional[String]
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
    "Optional",
    "Json",
    "Fn",
    "Task",
    "Channel",
    "Lazy",
    "ATS",
    "Range",
    "Bytes",
  ].concat(OPAQUE_TYPES.to_a)
  return Suggest.did_you_mean_among(word, RECORDS.keys.concat(ENUMS.keys), shared)
end

def signature_text(name: String) -> String
  found = Builtins.lookup(name)
  if found.some?
    return Text.quote(Builtins.signature(found.unwrap!))
  end

  return "-"
end

def ref_text(spec: String) -> String
  parts = spec.split("/")
  found = Builtins.ref(parts[0], parts[1].to_i!)
  if found.ok?
    return form_line(found.unwrap!)
  end

  return "-"
end

def help_text(help: Optional[String]) -> String
  case help
    some(text) -> return Text.quote(text)
    none -> return "-"
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
    Model.Rule.AtsCall -> return "AtsCall"
    Model.Rule.AtsNew -> return "AtsNew"
    Model.Rule.ChannelNew -> return "ChannelNew"
    Model.Rule.ChannelRecv -> return "ChannelRecv"
    Model.Rule.ChannelSend -> return "ChannelSend"
    Model.Rule.ChannelTarget -> return "ChannelTarget"
    Model.Rule.CodecDecode -> return "CodecDecode"
    Model.Rule.CodecEncode -> return "CodecEncode"
    Model.Rule.Error -> return "Error"
    Model.Rule.Identity -> return "Identity"
    Model.Rule.JsonCodec -> return "JsonCodec"
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
    Model.Rule.NativeCallback -> return "NativeCallback"
    Model.Rule.NativeClose -> return "NativeClose"
    Model.Rule.NativeClosed -> return "NativeClosed"
    Model.Rule.NativeMemoryBlock -> return "NativeMemoryBlock"
    Model.Rule.NativeStruct -> return "NativeStruct"
    Model.Rule.Ok -> return "Ok"
    Model.Rule.OkVoid -> return "OkVoid"
    Model.Rule.OptionalNone -> return "OptionalNone"
    Model.Rule.OptionalSome -> return "OptionalSome"
    Model.Rule.Prelude -> return "Prelude"
    Model.Rule.ProfileMeasure -> return "ProfileMeasure"
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
    Model.Rule.TaskMap -> return "TaskMap"
    Model.Rule.TaskSpawn -> return "TaskSpawn"
    Model.Rule.TaskSpawnOwning -> return "TaskSpawnOwning"
    Model.Rule.TaskTarget -> return "TaskTarget"
    Model.Rule.TestEq -> return "TestEq"
    Model.Rule.TestResult -> return "TestResult"
    _ -> return "?"
  end
end
