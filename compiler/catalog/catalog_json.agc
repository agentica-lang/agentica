## The JSON form of the builtin catalog (builtins.agc): the object of one builtin or builtin type and the array
## of every public one. `agentica help NAME --json`, `agentica help --json` and the `help` object of
## `agentica type-at` all print these, so a client reads the three with one parser. It lives in catalog/ so that the
## stages that answer queries (query/) can use it without importing the command line (app/).

import Types from "../syntax/types"
import Model from "builtin_model"
import Builtins from "builtins"
import {ENUMS, JSON_VALUE, OPAQUE_TYPES, OPERATOR_ONLY, PRELUDE_ONLY, PUBLIC_NAMES, RECORDS, STD_ONLY} from "builtins"
import {TYPE_DESCRIPTIONS} from "builtins_data"

struct TypeRow
  name: String
  kind: String
  signature: String
  description: String
  fields: List[Model.Named]
  variants: List[Model.Variant]
end

## The public builtin called `name`, or an error: a name in a std-only module (`HttpWire.service`), a prelude-only
## helper or a builtin written as an operator (List.concat is `+`) is not a public name, and neither is one that the
## catalog lacks.
def public(name: String) -> Result[Model.Builtin]
  hidden = PRELUDE_ONLY.include?(name) or OPERATOR_ONLY.include?(name)
  return error("not a public builtin") if Builtins.std_only_name?(name) or hidden

  Builtins.lookup(name).to_result("unknown builtin")
end

## Every public builtin and builtin type, in name order, each as `builtin` or `type_json` gives it. A type row has a
## `kind` and a function row has none, so a client tells them apart by it.
def catalog(ruby: Fn[Model.Builtin, String]) -> JSON.Value
  JSON.array(PUBLIC_NAMES.concat(PUBLIC_TYPES).sort.map do |name: String| entry_json(name, ruby) end)
end

def builtin_type(name: String) -> Optional[TypeRow]
  return none if !PUBLIC_TYPES.include?(name)

  row = TypeRow(
    name: name,
    kind: "opaque",
    signature: "type #{name}",
    description: TYPE_DESCRIPTIONS.get(name).unwrap_or(""),
    fields: [],
    variants: [],
  )

  return some(row.with(kind: "struct", signature: "struct #{name}", fields: RECORDS[name])) if RECORDS.has_key?(name)

  if ENUMS.has_key?(name)
    definition = ENUMS[name]
    parameters = ""
    if definition.parameters.size > 0
      parameters = "[#{definition.parameters.join(", ")}]"
    end

    return some(row.with(kind: "enum", signature: "enum #{name}#{parameters}", variants: definition.variants))
  end

  some(row)
end

def public_types() -> List[String] = PUBLIC_TYPES

def type_json(row: TypeRow) -> JSON.Value
  fields = {
    "name": JSON.from(row.name),
    "kind": JSON.from(row.kind),
    "signature": JSON.from(row.signature),
    "description": JSON.from(row.description),
  }

  if row.kind == "struct"
    fields = fields.put("fields", JSON.array(row.fields.map do |field: Model.Named| field_json(field) end))
  elsif row.kind == "enum"
    fields = fields.put("variants", JSON.array(row.variants.map do |variant: Model.Variant| variant_json(variant) end))
  end

  JSON.object(fields)
end

def field_text(field: Model.Named) -> String
  return "#{field.name}: #{Types.to_text(field.type)}" if !Builtins.default_present?(field.default)

  "#{field.name}: #{Types.to_text(field.type)} = #{Builtins.default_text(field.default)}"
end

def variant_text(variant: Model.Variant) -> String
  return variant.name if variant.payload.size == 0

  "#{variant.name}(#{variant.payload.map(&Types.to_text).join(", ")})"
end

## The JSON of a builtin: one object for a builtin with one form, else the name, the description and the effects of
## the first form with the object of each form under `overloads`. `ruby` gives the signature of a form in the Ruby
## method form (`map.key?(key: K) -> Bool` for `Map.has_key?`) or "" for none (check/ruby_form.agc: catalog/ cannot
## read the checker's alias tables, so the caller passes it); a form has it as `ruby`, or null. `name` and `signature`
## stay the name of the builtin.
def builtin(entry: Model.Builtin, ruby: Fn[Model.Builtin, String]) -> JSON.Value
  return form_json(entry, ruby) if entry.alternatives.size == 0

  forms = [entry].concat(entry.alternatives)
  JSON.object({
    "name": JSON.from(entry.name),
    "description": JSON.from(entry.description),
    "effects": strings(entry.effects),
    "overloads": JSON.array(forms.map do |form: Model.Builtin| form_json(form, ruby) end),
  })
end

private

PUBLIC_TYPES = TYPE_NAMES.filter do |name: String| !STD_ONLY.has_key?(name.split(".")[0]) end

TYPE_NAMES = RECORDS.keys.concat(ENUMS.keys).concat(OPAQUE_TYPES.to_a).push(JSON_VALUE).sort

# `unwrap!` cannot fail: a name that is not a type is one of PUBLIC_NAMES.
def entry_json(name: String, ruby: Fn[Model.Builtin, String]) -> JSON.Value
  case builtin_type(name)
    some(row) -> type_json(row)
    none -> builtin(Builtins.lookup(name).unwrap!, ruby)
  end
end

def field_json(field: Model.Named) -> JSON.Value
  default = JSON.null()
  if Builtins.default_present?(field.default)
    default = JSON.from(Builtins.default_text(field.default))
  end

  JSON.object({
    "name": JSON.from(field.name),
    "type": JSON.from(Types.to_text(field.type)),
    "default": default,
    "doc": JSON.null(),
  })
end

def variant_json(variant: Model.Variant) -> JSON.Value
  JSON.object({
    "name": JSON.from(variant.name),
    "payload": JSON.array(variant.payload.map do |type: Types.Type| JSON.from(Types.to_text(type)) end),
    "doc": JSON.null(),
  })
end

def form_json(form: Model.Builtin, ruby: Fn[Model.Builtin, String]) -> JSON.Value
  parameters = form.parameters.map do |parameter: Model.Named| parameter_json(parameter) end

  JSON.object({
    "name": JSON.from(form.name),
    "arity": JSON.from(form.parameters.size),
    "parameters": JSON.array(parameters),
    "result": JSON.from(Types.to_text(form.result)),
    "signature": JSON.from(Builtins.form_signature(form)),
    "ruby": text_or_null(ruby.call(form)),
    "effects": strings(form.effects),
    "description": JSON.from(form.description),
  })
end

# A parameter has `default` (the source text of its default value) only when it has one.
def parameter_json(parameter: Model.Named) -> JSON.Value
  fields = {"name": JSON.from(parameter.name), "type": JSON.from(Types.to_text(parameter.type))}
  if Builtins.default_present?(parameter.default)
    fields = fields.put("default", JSON.from(Builtins.default_text(parameter.default)))
  end

  JSON.object(fields)
end

def text_or_null(text: String) -> JSON.Value
  return JSON.null() if text == ""

  JSON.from(text)
end

def strings(items: List[String]) -> JSON.Value = JSON.array(items.map do |item: String| JSON.from(item) end)
