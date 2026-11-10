## The builtin functions and tables the linker, checker, and lowering read. The tables are module constants derived
## from builtins_data.agc and prelude_data.agc.

import Text from "../syntax/text"
import Types from "../syntax/types"
import Model from "builtin_model"
import {
  BUILTIN_ROWS,
  ENUMS as DATA_ENUMS,
  FAMILIES as DATA_FAMILIES,
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
EMPTY_FAMILIES: Map[String, List[String]] = {}

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

## The builtin types of a family (Family.Member): the records, enums and opaque types whose name starts with a family.
FAMILY_TYPE_NAMES = RECORDS.keys
  .concat(ENUMS.keys)
  .concat(DATA_OPAQUE_TYPES)
  .filter do |name: String| name.contains?(".") and DATA_FAMILIES.include?(name.split(".")[0]) end

export FAMILY_TYPES = Set.new(FAMILY_TYPE_NAMES)

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

## The builtin families (builtins_data.agc), each with its members: Family.Member is a group of functions, the rows
## named Family.Member.fn, or a builtin type of that name. Members are sorted by name.
export FAMILY_MEMBERS: Map[String, List[String]] = DATA_FAMILIES.reduce(EMPTY_FAMILIES) do |found, family|
  functions = ENTRIES.keys.filter do |name: String| name.starts_with?("#{family}.") and name.split(".").size == 3 end
  types = FAMILY_TYPE_NAMES.filter do |name: String| name.starts_with?("#{family}.") end
  found.put(family, functions.concat(types).map do |name: String| name.split(".")[1] end.uniq.sort)
end

## The public builtins a call can name, for the did-you-mean of an unknown name. Any other name with two dots
## (Native.Mutex.synchronize) is a method of a builtin type, written only on a value of it, so it is left out; a
## function of a family member (OpenSSL.Digest.sha256) stays.
export CALLABLE_NAMES = PUBLIC_NAMES.filter do |name|
  parts = name.split(".")
  parts.size < 3 or (FAMILY_MEMBERS.has_key?(parts[0]) and !FAMILY_TYPES.include?("#{parts[0]}.#{parts[1]}"))
end

export BARE_NAMES = Set.new(ENTRIES.keys.filter do |name| !name.contains?(".") end)

## True when the name is Family.Member.fn, a function of a member of a builtin family.
export def member_function?(name: String) -> Bool
  parts = name.split(".")
  return parts.size == 3 and member?(parts[0], parts[1])
end

## True when the family has the member: Family.Member names a group of functions or a builtin type.
export def member?(family: String, member: String) -> Bool
  found = FAMILY_MEMBERS.get(family)
  return found.some? and found.unwrap!.include?(member)
end

## True when Family.Member names a builtin type (a record, an enum or an opaque type) rather than a group of functions.
export def member_type?(family: String, member: String) -> Bool = FAMILY_TYPES.include?("#{family}.#{member}")

## The builtin of that name, or none when there is none (builtin-ref without an arity).
export def lookup(name: String) -> Optional[Model.Builtin] = ENTRIES.get(name)

## The form of a builtin that takes that many arguments, or an error when none does. A form with defaults takes every
## count from its required parameters to all of them; a form that takes exactly that many wins.
export def form_for(entry: Model.Builtin, arity: Int) -> Result[Model.Builtin]
  return form_among([entry].concat(entry.alternatives), arity)
end

## The form for a call: block is true when its last argument is a block (do ... end). A block call takes the block form
## of a builtin that also has a form without a block (File.open), whatever the count; otherwise it is form_for.
export def form_for_call(entry: Model.Builtin, arity: Int, block: Bool) -> Result[Model.Builtin]
  forms = [entry].concat(entry.alternatives)
  if block and block_form?(entry)
    return form_among(forms.filter do |form: Model.Builtin| takes_block?(form) end, arity)
  end

  return form_for(entry, arity)
end

## The form for a call of that many arguments with no block: the entry alone for a builtin with a block form
## (File.open), since its block form takes the block as its last argument, so it is not a form without one.
export def form_without_block(entry: Model.Builtin, arity: Int) -> Result[Model.Builtin]
  return form_among([entry], arity) if block_form?(entry)

  return form_for(entry, arity)
end

## The form of the builtin name for a call with that many arguments, the last a block when block is true.
export def call_ref(name: String, arity: Int, block: Bool) -> Result[Model.Builtin]
  entry = try lookup(name).to_result("unknown builtin")
  return form_for_call(entry, arity, block)
end

## True for a form whose body is a function of the prelude (Rule.Prelude), such as the block form of File.open.
export def prelude_form?(form: Model.Builtin) -> Bool
  case form.rule
    Model.Rule.Prelude -> return true
    _ -> return false
  end
end

## The builtin that `target[index]` runs for a target of that type: `Bytes.at`, or "" for a List or Map, which the VM
## indexes with an instruction of its own. The lowering and `Analysis.bodies` both ask here.
export def index_builtin(target: Types.Type) -> String
  return "Bytes.at" if Types.is?(target, "Bytes")

  return ""
end

## True when some parameter of the form has a default.
export def defaulted?(form: Model.Builtin) -> Bool = first_default(form) < form.parameters.size

## True when the last parameter of a form with defaults has none: it is an Fn, and the last argument (or the block)
## always goes to it, as in a function of the program (check/defaults.agc).
export def fn_last?(form: Model.Builtin) -> Bool
  return defaulted?(form) and !default_present?(form.parameters[form.parameters.size - 1].default)
end

## The fewest arguments a call of the form takes: the parameters before the first default, and the last Fn after them.
export def required_count(form: Model.Builtin) -> Int
  first = first_default(form)
  return first + 1 if fn_last?(form)

  return first
end

## What a call of the form expects: `2`, or `1 to 2` when the form has defaults. skipped leaves out the receiver of a
## call written as a method.
export def arity_text(form: Model.Builtin, skipped: Int) -> String
  total = form.parameters.size - skipped
  return total.to_s if !defaulted?(form)

  return "#{required_count(form) - skipped} to #{total}"
end

## The form of the builtin name that takes that many arguments (builtin-ref with an arity).
export def ref(name: String, arity: Int) -> Result[Model.Builtin]
  entry = try lookup(name).to_result("unknown builtin")
  return form_for(entry, arity)
end

## True for a name inside a std-only module, such as HttpWire.service.
export def std_only_name?(name: String) -> Bool = STD_ONLY.has_key?(module_of(name))

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
  return typed if !default_present?(parameter.default)

  return "#{typed} = #{default_text(parameter.default)}"
end

## A default as the source writes it: 6, 0.5, "x", true, nil, [], {}, "".bytes, none or Enum.Variant; "" for no
## default.
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
    Model.Default.EmptyBytes -> return "\"\".bytes"
    Model.Default.None -> return "none"
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

## The fields of each builtin record that have a default (Model.Named.default): a constructor may leave them out, as
## the fields of a struct with a default, and the lowering fills them in (lower_data.agc, lower_struct).
export def record_defaults() -> Map[String, Set[String]]
  found: Map[String, Set[String]] = {}
  for record in DATA_RECORDS
    defaulted = record.fields.filter do |field: Model.Named| default_present?(field.default) end
    found = found.put(record.name, Set.new(defaulted.map do |field: Model.Named| field.name end))
  end

  return found
end

## The builtin records with a field whose default is `none`: a program that builds one needs the Optional enum in its
## tables, since a constructor that leaves the field out builds `none` with no expression that names Optional. Only
## record fields count: a builtin parameter with a `none` default would need the same, and no builtin has one.
export def none_default_records() -> Set[String]
  names: List[String] = []
  for record in DATA_RECORDS
    if record.fields.any? do |field: Model.Named| none_default?(field.default) end
      names = names.push(record.name)
    end
  end

  return Set.new(names)
end

## The problem with the defaults of a record field, or "" when its default fits its type (default_fits?).
export def record_default_problem(record: String, field: Model.Named) -> String
  return "" if default_fits?(field)

  written = Types.to_text(field.type)
  return "the default of #{record}.#{field.name} is not #{article(written)} #{written}"
end

## The problem with the defaults of a builtin, or "" when it has none. A default is for a Plain or Prelude builtin with
## a single form, or with a block form as its one alternative (the other rules read the arguments by position, and a
## form picked by the number of arguments would be ambiguous; a block form is picked by the block), a parameter after a
## default has one too unless it is the last and an Fn, and each default has the type of its parameter (a variant is
## one of its enum, with no payload). The catalog text prints a problem, and a test fails on it.
export def default_problem(entry: Model.Builtin) -> String
  forms = [entry].concat(entry.alternatives)
  return "" if !forms.any? do |form: Model.Builtin| defaulted?(form) end

  if !forms.all? do |form: Model.Builtin| takes_defaults?(form.rule) end
    return "a default needs a Plain or Prelude builtin with no alternative form"
  end

  if entry.alternatives.size > 0 and !block_form?(entry)
    return "a builtin with defaults takes no alternative form but its block form"
  end

  # The block form repeats the parameters of the entry, so its own last Fn is the only parameter left to check.
  return form_default_problem(forms[forms.size - 1])
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

# True for the `none` default.
def none_default?(value: Model.Default) -> Bool
  case value
    Model.Default.None -> return true
    _ -> return false
  end
end

# The problem with the defaults of one form, or "".
def form_default_problem(entry: Model.Builtin) -> String
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

# The first form that takes exactly that many arguments, else the first whose defaults let it take that many.
def form_among(forms: List[Model.Builtin], arity: Int) -> Result[Model.Builtin]
  for form in forms
    return ok(form) if form.parameters.size == arity
  end

  for form in forms
    return ok(form) if arity >= required_count(form) and arity < form.parameters.size
  end

  return error("no form with that arity")
end

# True when the last parameter of the form is a function, which a block fills.
def takes_block?(form: Model.Builtin) -> Bool
  return form.parameters.size > 0 and Types.is?(form.parameters[form.parameters.size - 1].type, "Fn")
end

# True for a builtin whose one alternative is its block form: the same parameters and defaults with a last Fn after
# them (File.open with a block). Its forms are told apart by the block, not by the count of arguments.
def block_form?(entry: Model.Builtin) -> Bool
  return false if entry.alternatives.size != 1 or takes_block?(entry)

  alternative = entry.alternatives[0]
  return false if !takes_block?(alternative) or alternative.parameters.size != entry.parameters.size + 1

  index = 0
  while index < entry.parameters.size
    return false if parameter_text(entry.parameters[index]) != parameter_text(alternative.parameters[index])

    index += 1
  end

  return true
end

# The index of the first parameter with a default, or the number of parameters when none has one.
def first_default(form: Model.Builtin) -> Int
  at = 0
  while at < form.parameters.size
    return at if default_present?(form.parameters[at].default)

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
    Model.Default.Whole(_) -> return Types.is?(type, "Int")
    Model.Default.Real(_) -> return Types.is?(type, "Float")
    Model.Default.Text(_) -> return Types.is?(type, "String")
    Model.Default.Flag(_) -> return Types.is?(type, "Bool")
    Model.Default.Nothing -> return Types.is?(type, "Nil")
    Model.Default.EmptyList -> return Types.is?(type, "List")
    Model.Default.EmptyMap -> return Types.is?(type, "Map")
    Model.Default.EmptyBytes -> return Types.is?(type, "Bytes")
    Model.Default.None -> return Types.is?(type, "Optional")
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
  return "an" if "AEIOU".contains?(word.slice(0, 1))

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
  return name.slice(0, dot.unwrap!) if dot.some?

  return ""
end
