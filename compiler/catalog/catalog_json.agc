## The JSON form of the builtin catalog (builtins.agc): the object of one builtin and the array of every public one.
## `agentica help NAME --json`, `agentica help --json` and the `help` object of `agentica type-at` all print these, so
## a client reads the three with one parser. It lives in catalog/ so that the stages that answer queries (query/) can
## use it without importing the command line (app/).

import Types from "../syntax/types"
import Model from "builtin_model"
import Builtins from "builtins"
import {OPERATOR_ONLY, PRELUDE_ONLY, PUBLIC_NAMES} from "builtins"

## The public builtin called `name`, or an error: a name in a std-only module (`HttpWire.service`), a prelude-only
## helper or a builtin written as an operator (List.concat is `+`) is not a public name, and neither is one that the
## catalog lacks.
def public(name: String) -> Result[Model.Builtin]
  hidden = PRELUDE_ONLY.include?(name) or OPERATOR_ONLY.include?(name)
  return error("not a public builtin") if Builtins.std_only_name?(name) or hidden

  Builtins.lookup(name).to_result("unknown builtin")
end

## Every public builtin, in name order, each as `builtin` gives it.
def catalog(ruby: Fn[Model.Builtin, String]) -> JSON.Value
  # `unwrap!` cannot fail: PUBLIC_NAMES are keys of the same ENTRIES that `Builtins.lookup` reads.
  JSON.array(PUBLIC_NAMES.sort.map do |name: String| builtin(Builtins.lookup(name).unwrap!, ruby) end)
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
