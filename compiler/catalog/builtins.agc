## The builtin functions and tables the linker, checker, and lowering read. The tables are module constants derived
## from builtins_data.agc and prelude_data.agc.

import Text from "../syntax/text"
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

## The form of a builtin that takes that many arguments, or an error when none does. A form with defaults takes every
## count from its required parameters to all of them; a form that takes exactly that many wins.
export def form_for(entry: Model.Builtin, arity: Int) -> Result[Model.Builtin]
  if entry.parameters.size == arity
    return ok(entry)
  end

  for alternative in entry.alternatives
    if alternative.parameters.size == arity
      return ok(alternative)
    end
  end

  for form in [entry].concat(entry.alternatives)
    if arity >= required_count(form) and arity < form.parameters.size
      return ok(form)
    end
  end

  return error("no form with that arity")
end

## True when some parameter of the form has a default.
export def defaulted?(form: Model.Builtin) -> Bool
  return first_default(form) < form.parameters.size
end

## True when the last parameter of a form with defaults has none: it is an Fn, and the last argument (or the block)
## always goes to it, as in a function of the program (check/defaults.agc).
export def fn_last?(form: Model.Builtin) -> Bool
  return defaulted?(form) and !default_present?(form.parameters[form.parameters.size - 1].default)
end

## The fewest arguments a call of the form takes: the parameters before the first default, and the last Fn after them.
export def required_count(form: Model.Builtin) -> Int
  first = first_default(form)
  if fn_last?(form)
    return first + 1
  end

  return first
end

## What a call of the form expects: `2`, or `1 to 2` when the form has defaults. skipped leaves out the receiver of a
## call written as a method.
export def arity_text(form: Model.Builtin, skipped: Int) -> String
  total = form.parameters.size - skipped
  if !defaulted?(form)
    return total.to_s
  end

  return "#{required_count(form) - skipped} to #{total}"
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
  parameters = form.parameters.map do |parameter: Model.Named| parameter_text(parameter) end
  return "#{form.name}(#{parameters.join(", ")}) -> #{Types.to_text(form.result)}"
end

## A parameter as a signature writes it: `level: Int = 6`.
export def parameter_text(parameter: Model.Named) -> String
  typed = "#{parameter.name}: #{Types.to_text(parameter.type)}"
  if !default_present?(parameter.default)
    return typed
  end

  return "#{typed} = #{default_text(parameter.default)}"
end

## A default as the source writes it: 6, 0.5, "x", true, nil, [], {} or Enum.Variant; "" for no default.
export def default_text(value: Model.Default) -> String
  case value
    Model.Default.Absent -> return ""
    Model.Default.Whole(number) -> return number.to_s
    Model.Default.Real(number) -> return number.to_s
    Model.Default.Text(text) -> return Text.quote(text)
    Model.Default.Flag(flag) -> return flag.to_s
    Model.Default.Nothing -> return "nil"
    Model.Default.EmptyList -> return "[]"
    Model.Default.EmptyMap -> return "{}"
    Model.Default.Variant(name) -> return name
  end
end

## True for a default (not Absent).
export def default_present?(value: Model.Default) -> Bool
  case value
    Model.Default.Absent -> return false
    _ -> return true
  end
end

## The problem with the defaults of a builtin, or "" when it has none. A default is for a Plain or Prelude builtin with
## a single form (the other rules read the arguments by position, and a form picked by the number of arguments would
## be ambiguous), a parameter after a default has one too unless it is the last and an Fn, and each default has the
## type of its parameter (a variant is one of its enum, with no payload). The catalog text prints a problem, and a test
## fails on it.
export def default_problem(entry: Model.Builtin) -> String
  forms = [entry].concat(entry.alternatives)
  if !forms.any? do |form: Model.Builtin| defaulted?(form) end
    return ""
  end

  if !takes_defaults?(entry.rule) or entry.alternatives.size > 0
    return "a default needs a Plain or Prelude builtin with no alternative form"
  end

  last = entry.parameters.size - 1
  at = first_default(entry)
  while at < entry.parameters.size
    parameter = entry.parameters[at]
    if !default_present?(parameter.default) and !(at == last and Types.is?(parameter.type, "Fn"))
      return "parameter #{parameter.name} has no default but follows one"
    end

    if default_present?(parameter.default) and !default_fits?(parameter)
      written = Types.to_text(parameter.type)
      return "the default of #{parameter.name} is not #{article(written)} #{written}"
    end

    at += 1
  end

  return ""
end

## The builtin enums that some builtin gives a default variant of: the lowering keeps them in the tables of every
## program, because a call that leaves the argument out builds the variant with no expression that names the enum. A
## function, not a constant: a constant cannot call variant_enum.
export def default_enums() -> Set[String]
  names: List[String] = []
  for row in BUILTIN_ROWS
    for parameter in row.parameters
      name = variant_enum(parameter.default)
      if name != ""
        names = names.push(name)
      end
    end
  end

  return Set.new(names)
end

# The index of the first parameter with a default, or the number of parameters when none has one.
def first_default(form: Model.Builtin) -> Int
  at = 0
  while at < form.parameters.size
    if default_present?(form.parameters[at].default)
      return at
    end

    at += 1
  end

  return at
end

# True for the Plain and Prelude rules: the arguments are checked against the parameters, one each.
def takes_defaults?(rule: Model.Rule) -> Bool
  case rule
    Model.Rule.Plain -> return true
    Model.Rule.Prelude -> return true
    _ -> return false
  end
end

# True when the default has the type of its parameter.
def default_fits?(parameter: Model.Named) -> Bool
  type = parameter.type
  case parameter.default
    Model.Default.Absent -> return true
    Model.Default.Whole(number) -> return Types.is?(type, "Int")
    Model.Default.Real(number) -> return Types.is?(type, "Float")
    Model.Default.Text(text) -> return Types.is?(type, "String")
    Model.Default.Flag(flag) -> return Types.is?(type, "Bool")
    Model.Default.Nothing -> return Types.is?(type, "Nil")
    Model.Default.EmptyList -> return Types.is?(type, "List")
    Model.Default.EmptyMap -> return Types.is?(type, "Map")
    Model.Default.Variant(name) -> return variant_fits?(type, name)
  end
end

# True for "Enum.Variant" when the type is that builtin enum and the variant exists with no payload.
def variant_fits?(type: Types.Type, name: String) -> Bool
  parts = name.split(".")
  if parts.size != 2 or !Types.is?(type, "Enum") or Types.name(type) != parts[0] or !ENUMS.has_key?(parts[0])
    return false
  end

  return ENUMS[parts[0]].variants.any? do |variant: Model.Variant|
    variant.name == parts[1] and variant.payload.size == 0
  end
end

# "an" before a vowel, else "a".
def article(word: String) -> String
  if "AEIOU".contains?(word.slice(0, 1))
    return "an"
  end

  return "a"
end

# The enum of a default variant, or "".
def variant_enum(value: Model.Default) -> String
  case value
    Model.Default.Variant(name) -> return name.split(".")[0]
    _ -> return ""
  end
end

def module_of(name: String) -> String
  dot = name.index_of(".")
  if dot.ok?
    return name.slice(0, dot.unwrap!)
  end

  return ""
end
