## The Ruby form of a builtin, which `agentica help`, the JSON catalog and the helps of the checker show instead of
## the name of the builtin: `List.filter` is written `list.select()`, `Result.ok?` is written `r.ok?()`. Both names are
## accepted (check_tables.agc, `method_aliases`); only the text speaks Ruby. A builtin has a method form when a method
## alias points to it (`List.select`) or when it is a method of its own kind (`Result.ok?`, the same rule as the
## checker's `catalog_method`). A builtin that is no method of any kind (`File.read`) has none.

import Types from "../syntax/types"
import Model from "../catalog/builtin_model"
import Builtins from "../catalog/builtins"
import {ENTRIES, METHOD_RECORDS} from "../catalog/builtins"
import Tables from "check_tables"

## `Kind.method` of the Ruby method form of the builtin `name` (`List.select` for `List.filter`), or "" when it has
## none.
def method_key(name: String) -> String
  aliased = by_builtin().get(name)
  return aliased.unwrap! if aliased.some?

  entry = ENTRIES.get(name)
  return "" if entry.none? or entry.unwrap!.parameters.size == 0

  kind = parameter_kind(entry.unwrap!.parameters[0].type)
  module = module_of(kind)
  return "" if module.none? or !name.start_with?("#{module.unwrap!}.")

  key = "#{kind}.#{name.slice(module.unwrap!.length + 1, name.length - module.unwrap!.length - 1)}"
  taken = Tables.method_aliases().get(key)
  return "" if taken.some? and taken.unwrap! != name

  key
end

## The receiver kind of a builtin whose first parameter has this type: its tag (`String`, `List`, ...), but Mutex for
## Native.Mutex and Builder for Bytes.Builder, the opaque types with methods, Error for the builtin record Error, and
## the name of a record of a family with methods (`Time.DateTime`, METHOD_RECORDS).
def parameter_kind(type: Types.Type) -> String
  return "Mutex" if Types.is?(type, "Opaque") and Types.name(type) == "Native.Mutex"
  return "Builder" if Types.is?(type, "Opaque") and Types.name(type) == "Bytes.Builder"
  return "Error" if Types.error?(type)
  return Types.name(type) if method_record?(type)

  Types.tag(type)
end

## True when the type is a record of a family with methods: a name it has no field of is a method (`t.to_i`).
def method_record?(type: Types.Type) -> Bool = Types.is?(type, "Struct") and METHOD_RECORDS.include?(Types.name(type))

## The builtin module that holds the methods of a receiver kind: the table of the checker, or the record itself.
def module_of(kind: String) -> Optional[String]
  return some(kind) if METHOD_RECORDS.include?(kind)

  Tables.method_modules().get(kind)
end

## The method name of the Ruby form of the builtin `name` (`select` for `List.filter`), or "".
def method_name(name: String) -> String
  key = method_key(name)
  return "" if key == ""

  # The kind of a record has dots of its own (Time.DateTime.to_i); a method name has none.
  parts = key.split(".")
  parts[parts.size - 1]
end

## True when `method` is a Ruby name of the builtin `name` on the receiver `kind`: its Ruby form, or a synonym of it
## (`length` and `size`).
def ruby_name?(kind: String, method: String, name: String) -> Bool
  method_name(name) == method or synonym?("#{kind}.#{method}")
end

## The signature of one form of a builtin in its Ruby form, `s.strip() -> String` or `list.push(value: T) -> List[T]`,
## or "" when the builtin has none. The receiver is the first parameter.
def signature(form: Model.Builtin) -> String = signature_as(form, method_name(form.name))

## The Ruby form of `form` written with the method name `method`, which is its own or a synonym of it (`s.size()` for
## `String.length`); "" when `method` is "".
def signature_as(form: Model.Builtin, method: String) -> String
  return "" if method == ""

  rest = form.parameters.drop(1).map do |parameter: Model.Named| Builtins.parameter_text(parameter) end

  "#{form.parameters[0].name}.#{method}(#{rest.join(", ")}) -> #{Types.to_text(form.result)}"
end

## True when `method` is a way to write the builtin `name` as a method: its Ruby name or a synonym of it, on any kind.
def written_as?(name: String, method: String) -> Bool
  return true if method_name(name) == method

  aliases = Tables.method_aliases()
  for key in Tables.ruby_synonyms()
    # A synonym that `method_aliases` lacks is skipped (a test keeps the two lists in step).
    target = aliases.get(key)
    return true if key.end_with?(".#{method}") and target.some? and target.unwrap! == name
  end

  false
end

## The Ruby form of a builtin name as a suggestion: `list.select` for `List.filter`; `name` when it has none.
def shown(name: String) -> String
  method = method_name(name)
  entry = ENTRIES.get(name)
  return name if method == "" or entry.none?

  "#{entry.unwrap!.parameters[0].name}.#{method}"
end

## True when the alias key `Kind.method` is a second Ruby name (`List.collect`, `String.size`): accepted, and never
## shown in a text.
def synonym?(key: String) -> Bool = Tables.ruby_synonyms().any? do |known: String| known == key end

private

# The alias key of each builtin that has a Ruby name of its own; the first key in name order wins.
def by_builtin() -> Map[String, String]
  aliases = Tables.method_aliases()
  found: Map[String, String] = {}
  for key in aliases.keys.sort
    target = aliases[key]
    if target != "self" and !synonym?(key) and !found.has_key?(target)
      found = found.put(target, key)
    end
  end

  found
end
