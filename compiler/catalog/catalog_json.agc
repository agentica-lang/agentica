## The JSON form of the builtin catalog (builtins.agc): the object of one builtin and the array of every public one.
## `agentica help NAME --json`, `agentica help --json` and the `help` object of `agentica type-at` all print these, so
## a client reads the three with one parser. It lives in catalog/ so that the stages that answer queries (query/) can
## use it without importing the command line (app/).

import Types from "../syntax/types"
import Model from "builtin_model"
import Builtins from "builtins"
import RubyForm from "ruby_form"
import {PRELUDE_ONLY, PUBLIC_NAMES} from "builtins"

## The public builtin called `name`, or an error: a name in a std-only module (`HttpWire.service`) or a prelude-only
## helper is not a public name, and neither is one that the catalog lacks.
export def public(name: String) -> Result[Model.Builtin]
  if Builtins.std_only_name?(name) or PRELUDE_ONLY.include?(name)
    return error("not a public builtin")
  end
  return Builtins.lookup(name)
end

## Every public builtin, in name order, each as `builtin` gives it.
export def catalog() -> Json
  # `unwrap!` cannot fail: PUBLIC_NAMES are keys of the same ENTRIES that `Builtins.lookup` reads.
  return JSON.array(PUBLIC_NAMES.sort.map do |name: String| builtin(Builtins.lookup(name).unwrap!) end)
end

## The JSON of a builtin: one object for a builtin with one form, else the name, the description and the effects of
## the first form with the object of each form under `overloads`. `ruby` of a form is its signature in the Ruby method
## form (`s.strip() -> String` for `String.trim`), or null when the builtin has none; `name` and `signature` stay the
## name of the builtin.
export def builtin(entry: Model.Builtin) -> Json
  if entry.alternatives.size == 0
    return form_json(entry)
  end
  forms = [entry].concat(entry.alternatives)
  return JSON.object({
    "name": JSON.from(entry.name),
    "description": JSON.from(entry.description),
    "effects": strings(entry.effects),
    "overloads": JSON.array(forms.map do |form: Model.Builtin| form_json(form) end),
  })
end

def form_json(form: Model.Builtin) -> Json
  parameters = form.parameters.map do |parameter: Model.Named|
    JSON.object({"name": JSON.from(parameter.name), "type": JSON.from(Types.to_text(parameter.type))})
  end
  return JSON.object({
    "name": JSON.from(form.name),
    "arity": JSON.from(form.parameters.size),
    "parameters": JSON.array(parameters),
    "result": JSON.from(Types.to_text(form.result)),
    "signature": JSON.from(Builtins.form_signature(form)),
    "ruby": ruby(form),
    "effects": strings(form.effects),
    "description": JSON.from(form.description),
  })
end

def ruby(form: Model.Builtin) -> Json
  text = RubyForm.signature(form)
  if text == ""
    return JSON.from(nil)
  end
  return JSON.from(text)
end

def strings(items: List[String]) -> Json
  return JSON.array(items.map do |item: String| JSON.from(item) end)
end
