## The text form of the builtin catalog, for tests. See catalog_text. The golden is
## tests/fixtures/frontend/catalog/catalog.text.

import Suggest from "../syntax/suggest"
import Text from "../syntax/text"
import Types from "../syntax/types"
import Model from "builtin_model"
import Builtins from "builtins"
import {
  BARE_NAMES, CALLABLE_NAMES, ENTRIES, ENUMS, HANDLES, OPAQUE_TYPES, PRELUDE, PRELUDE_ONLY, PUBLIC_NAMES, RECORDS,
  RESERVED, STD_ONLY,
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

  lines.join("\n")
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

  lines
end

def form_line(form: Model.Builtin) -> String
  (
    "#{Builtins.form_signature(form)} shape=#{shape_text(form)} rule=#{rule_name(form.rule)} " +
    "impl=#{Text.quote(form.implementation)} effects=#{quoted_list(form.effects)} " +
    "desc=#{Text.quote(form.description)}"
  )
end

# The parameter and result types with their variants written out, because to_text prints Struct("X"), Enum("X", []) and
# Var("X") alike.
def shape_text(form: Model.Builtin) -> String
  parameters = form.parameters.map do |parameter: Model.Named| shape_parameter(parameter) end
  "(#{parameters.join(", ")}) -> #{Types.debug_text(form.result)}"
end

# A parameter type, then ` = default` when it has one.
def shape_parameter(parameter: Model.Named) -> String
  written = Types.debug_text(parameter.type)
  return "#{written} = #{Builtins.default_text(parameter.default)}" if Builtins.default_present?(parameter.default)

  written
end

def record_lines() -> List[String]
  lines: List[String] = []
  for name in RECORDS.keys.sort
    fields = RECORDS[name].map do |field: Model.Named| "#{field.name}: #{shape_parameter(field)}" end
    lines = lines.push("record #{name} #{fields.join(", ")}")
    for field in RECORDS[name]
      problem = Builtins.record_default_problem(name, field)
      if problem != ""
        lines = lines.push("  default-problem #{Text.quote(problem)}")
      end
    end
  end

  lines
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

  lines
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

  [
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
  return "equality" if limit.equality

  names = limit.allowed.map do |type: Types.Type| Types.debug_text(type) end
  names.join("/")
end

def probe_line(probe: String) -> String
  colon = probe.index_of(":").unwrap!
  kind = probe.slice(0, colon)
  rest = probe.slice(colon + 1, probe.length - colon - 1)
  case kind
    "near" ->
      near = Suggest.did_you_mean_among(rest, CALLABLE_NAMES, [])
      "#{probe} -> #{help_text(near)}"
    "ref" -> "#{probe} -> #{ref_text(rest)}"
    "type" -> "#{probe} -> #{help_text(type_help(rest))}"
    "sig" -> "#{probe} -> #{signature_text(rest)}"
    "disp" -> "#{probe} -> #{Text.quote(Types.display_name(rest))}"
    _ -> "#{probe} -> #{Builtins.std_only_name?(rest)}"
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
    "Codec",
    "ATS",
    "Range",
    "Bytes",
  ].concat(OPAQUE_TYPES.to_a)

  Suggest.did_you_mean_among(word, RECORDS.keys.concat(ENUMS.keys), shared)
end

def signature_text(name: String) -> String
  found = Builtins.lookup(name)
  return Text.quote(Builtins.signature(found.unwrap!)) if found.some?

  "-"
end

def ref_text(spec: String) -> String
  parts = spec.split("/")
  found = Builtins.ref(parts[0], parts[1].to_i!)
  return form_line(found.unwrap!) if found.ok?

  "-"
end

def help_text(help: Optional[String]) -> String
  case help
    some(text) -> Text.quote(text)
    none -> "-"
  end
end

def variant_text(variant: Model.Variant) -> String
  return variant.name if variant.payload.size == 0

  payload = Types.debug_list(variant.payload)
  "#{variant.name}(#{payload})"
end

def quoted_list(items: List[String]) -> String
  texts = items.map do |item: String| Text.quote(item) end
  quoted = texts.join(", ")
  "[#{quoted}]"
end

def rule_name(rule: Model.Rule) -> String
  case rule
    Model.Rule.Plain -> "Plain"
    Model.Rule.AddressSend -> "AddressSend"
    Model.Rule.AtsCall -> "AtsCall"
    Model.Rule.AtsNew -> "AtsNew"
    Model.Rule.ChannelAddress -> "ChannelAddress"
    Model.Rule.ChannelNew -> "ChannelNew"
    Model.Rule.ChannelRecv -> "ChannelRecv"
    Model.Rule.ChannelSend -> "ChannelSend"
    Model.Rule.ChannelTarget -> "ChannelTarget"
    Model.Rule.CodecDecode -> "CodecDecode"
    Model.Rule.CodecEncode -> "CodecEncode"
    Model.Rule.CodecMembers -> "CodecMembers"
    Model.Rule.Error -> "Error"
    Model.Rule.ErrorKind -> "ErrorKind"
    Model.Rule.Identity -> "Identity"
    Model.Rule.JsonDecode -> "JsonDecode"
    Model.Rule.JsonEncode -> "JsonEncode"
    Model.Rule.JsonFrom -> "JsonFrom"
    Model.Rule.JsonSchema -> "JsonSchema"
    Model.Rule.ListAll -> "ListAll"
    Model.Rule.ListAny -> "ListAny"
    Model.Rule.ListAppend -> "ListAppend"
    Model.Rule.ListAt -> "ListAt"
    Model.Rule.ListConcat -> "ListConcat"
    Model.Rule.ListCount -> "ListCount"
    Model.Rule.ListEach -> "ListEach"
    Model.Rule.ListFilter -> "ListFilter"
    Model.Rule.ListMap -> "ListMap"
    Model.Rule.ListReduce -> "ListReduce"
    Model.Rule.ListRepeat -> "ListRepeat"
    Model.Rule.ListReverse -> "ListReverse"
    Model.Rule.ListSet -> "ListSet"
    Model.Rule.ListSize -> "ListSize"
    Model.Rule.ListSort -> "ListSort"
    Model.Rule.ListSortBy -> "ListSortBy"
    _ -> later_rule_name(rule)
  end
end

def later_rule_name(rule: Model.Rule) -> String
  case rule
    Model.Rule.MapDelete -> "MapDelete"
    Model.Rule.MapGet -> "MapGet"
    Model.Rule.MapGetDefault -> "MapGetDefault"
    Model.Rule.MapHas -> "MapHas"
    Model.Rule.MapKeys -> "MapKeys"
    Model.Rule.MapPut -> "MapPut"
    Model.Rule.MapSize -> "MapSize"
    Model.Rule.MapValues -> "MapValues"
    Model.Rule.NativeCallback -> "NativeCallback"
    Model.Rule.NativeClose -> "NativeClose"
    Model.Rule.NativeClosed -> "NativeClosed"
    Model.Rule.NativeMemoryBlock -> "NativeMemoryBlock"
    Model.Rule.NativeStruct -> "NativeStruct"
    Model.Rule.NativeSynchronize -> "NativeSynchronize"
    Model.Rule.Ok -> "Ok"
    Model.Rule.OkVoid -> "OkVoid"
    Model.Rule.OptionalNone -> "OptionalNone"
    Model.Rule.OptionalSome -> "OptionalSome"
    Model.Rule.Prelude -> "Prelude"
    Model.Rule.ProfileMeasure -> "ProfileMeasure"
    Model.Rule.ResultDefault -> "ResultDefault"
    Model.Rule.ResultMessage -> "ResultMessage"
    Model.Rule.ResultOk -> "ResultOk"
    Model.Rule.ResultUnwrap -> "ResultUnwrap"
    Model.Rule.SetAdd -> "SetAdd"
    Model.Rule.SetCombine -> "SetCombine"
    Model.Rule.SetInclude -> "SetInclude"
    Model.Rule.SetNew -> "SetNew"
    Model.Rule.SetQuery -> "SetQuery"
    Model.Rule.SetSubset -> "SetSubset"
    Model.Rule.SetToA -> "SetToA"
    Model.Rule.Show -> "Show"
    Model.Rule.TaskAwait -> "TaskAwait"
    Model.Rule.TaskAwaitTimeout -> "TaskAwaitTimeout"
    Model.Rule.TaskMap -> "TaskMap"
    Model.Rule.TaskMonitor -> "TaskMonitor"
    Model.Rule.TaskSpawn -> "TaskSpawn"
    Model.Rule.TaskSpawnOwning -> "TaskSpawnOwning"
    Model.Rule.TaskTarget -> "TaskTarget"
    Model.Rule.TestEq -> "TestEq"
    Model.Rule.TestResult -> "TestResult"
    _ -> "?"
  end
end
