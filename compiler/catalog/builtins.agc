## The builtin functions and tables the linker, checker, and lowering read. The tables are module constants derived
## from builtins_data.agc and prelude_data.agc.

import Types from "../syntax/types"
import Model from "builtin_model"
import {
  BUILTIN_ROWS,
  ENUMS as DATA_ENUMS,
  HANDLE_TYPES,
  OPAQUE_TYPES as DATA_OPAQUE_TYPES,
  RECORDS as DATA_RECORDS,
  RESERVED_TYPE_NAMES,
  STD_ONLY_IMPORTS,
} from "builtins_data"
import {PRELUDE_ONLY as DATA_PRELUDE_ONLY, ROWS as PRELUDE_ROWS} from "prelude_data"

EMPTY_BUILTINS: Map[String, Model.Builtin] = {}
EMPTY_RECORDS: Map[String, List[Model.Named]] = {}
EMPTY_ENUMS: Map[String, Model.EnumDef] = {}
EMPTY_PRELUDE: Map[String, Model.PreludeRow] = {}

export ENTRIES: Map[String, Model.Builtin] = BUILTIN_ROWS.reduce(EMPTY_BUILTINS) do |found, row|
  found.put(row.name, row)
end

export RECORDS: Map[String, List[Model.Named]] = DATA_RECORDS.reduce(EMPTY_RECORDS) do |found, record|
  found.put(record.name, record.fields)
end

export ENUMS: Map[String, Model.EnumDef] = DATA_ENUMS.reduce(EMPTY_ENUMS) do |found, definition|
  found.put(definition.name, definition)
end

export OPAQUE_TYPES = Set.new(DATA_OPAQUE_TYPES)
export HANDLES = Set.new(HANDLE_TYPES)
export RESERVED = Set.new(RESERVED_TYPE_NAMES)

export STD_ONLY = STD_ONLY_IMPORTS

export PRELUDE: Map[String, Model.PreludeRow] = PRELUDE_ROWS.reduce(EMPTY_PRELUDE) do |found, row|
  found.put(row.name, row)
end

export PRELUDE_ONLY = Set.new(DATA_PRELUDE_ONLY)

export PUBLIC_NAMES = ENTRIES.keys.filter do |name|
  !STD_ONLY.has_key?(name.split(".")[0]) and !PRELUDE_ONLY.include?(name)
end

export BARE_NAMES = Set.new(ENTRIES.keys.filter do |name| !name.contains?(".") end)

## The builtin of that name, or an error when there is none (builtin-ref without an arity).
export def lookup(name: String) -> Result[Model.Builtin]
  return ENTRIES.get(name)
end

## The form of a builtin that takes that many arguments, or an error when none does.
export def form_for(entry: Model.Builtin, arity: Int) -> Result[Model.Builtin]
  if entry.parameters.size == arity
    return ok(entry)
  end
  for alternative in entry.alternatives
    if alternative.parameters.size == arity
      return ok(alternative)
    end
  end
  return error("no form with that arity")
end

## The form of the builtin name that takes that many arguments (builtin-ref with an arity).
export def ref(name: String, arity: Int) -> Result[Model.Builtin]
  entry = try lookup(name)
  return form_for(entry, arity)
end

## True for a name inside a std-only module, such as HttpWire.service.
export def std_only_name?(name: String) -> Bool
  return STD_ONLY.has_key?(module_of(name))
end

## The signature of every form of a builtin, one per line: name(param: Type, ...) -> Result.
export def signature(entry: Model.Builtin) -> String
  forms = [entry].concat(entry.alternatives)
  return forms.map do |form: Model.Builtin| form_signature(form) end.join("\n")
end

## The signature of one form.
export def form_signature(form: Model.Builtin) -> String
  parameters = form.parameters.map do |parameter: Model.Named|
    "#{parameter.name}: #{Types.to_text(parameter.type)}"
  end
  return "#{form.name}(#{parameters.join(", ")}) -> #{Types.to_text(form.result)}"
end

def module_of(name: String) -> String
  dot = name.index_of(".")
  if dot.ok?
    return name.slice(0, dot.unwrap!)
  end
  return ""
end
