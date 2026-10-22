## The Ruby form of a builtin, which `agentica help`, the JSON catalog and the helps of the checker show instead of the
## name of the builtin: `String.trim` is written `s.strip()`, `Result.ok?` is written `r.ok?()`. Both names are accepted
## (check_tables.agc, `method_aliases`); only the text speaks Ruby. A builtin has a method form when a method alias
## points to it (`String.strip`) or when it is a method of its own kind (`Result.ok?`, the same rule as the checker's
## `catalog_method`). A builtin that is no method of any kind (`File.read`) has none.

import Types from "../syntax/types"
import Model from "builtin_model"
import {ENTRIES} from "builtins"
import Tables from "../check/check_tables"

## `Kind.method` of the Ruby method form of the builtin `name` (`String.strip` for `String.trim`), or "" when it has
## none.
export def method_key(name: String) -> String
  aliased = by_builtin().get(name)
  if aliased.ok?
    return aliased.unwrap!
  end
  entry = ENTRIES.get(name)
  if !entry.ok? or entry.unwrap!.parameters.size == 0
    return ""
  end
  kind = Types.tag(entry.unwrap!.parameters[0].type)
  module = Tables.method_modules().get(kind)
  if !module.ok? or !name.starts_with?("#{module.unwrap!}.")
    return ""
  end
  key = "#{kind}.#{name.slice(module.unwrap!.length + 1, name.length - module.unwrap!.length - 1)}"
  taken = Tables.method_aliases().get(key)
  if taken.ok? and taken.unwrap! != name
    return ""
  end
  return key
end

## The method name of the Ruby form of the builtin `name` (`strip` for `String.trim`), or "".
export def method_name(name: String) -> String
  key = method_key(name)
  if key == ""
    return ""
  end
  return key.slice(key.index_of(".").unwrap! + 1, key.length - key.index_of(".").unwrap! - 1)
end

## True when `method` is a Ruby name of the builtin `name` on the receiver `kind`: its Ruby form, or a synonym of it
## (`length` and `size`).
export def ruby_name?(kind: String, method: String, name: String) -> Bool
  return method_name(name) == method or synonym?("#{kind}.#{method}")
end

## The signature of one form of a builtin in its Ruby form, `s.strip() -> String` or `list.push(value: T) -> List[T]`,
## or "" when the builtin has none. The receiver is the first parameter.
export def signature(form: Model.Builtin) -> String
  return signature_as(form, method_name(form.name))
end

## The Ruby form of `form` written with the method name `method`, which is its own or a synonym of it (`s.size()` for
## `String.length`); "" when `method` is "".
export def signature_as(form: Model.Builtin, method: String) -> String
  if method == ""
    return ""
  end
  rest = form.parameters.drop(1).map do |parameter: Model.Named|
    "#{parameter.name}: #{Types.to_text(parameter.type)}"
  end
  return "#{form.parameters[0].name}.#{method}(#{rest.join(", ")}) -> #{Types.to_text(form.result)}"
end

## True when `method` is a way to write the builtin `name` as a method: its Ruby name or a synonym of it, on any kind.
export def written_as?(name: String, method: String) -> Bool
  if method_name(name) == method
    return true
  end
  aliases = Tables.method_aliases()
  for key in Tables.ruby_synonyms()
    if key.ends_with?(".#{method}") and aliases[key] == name
      return true
    end
  end
  return false
end

## The Ruby form of a builtin name as a suggestion: `s.strip` for `String.trim`; `name` when it has none.
export def shown(name: String) -> String
  method = method_name(name)
  entry = ENTRIES.get(name)
  if method == "" or !entry.ok?
    return name
  end
  return "#{entry.unwrap!.parameters[0].name}.#{method}"
end

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
  return found
end

def synonym?(key: String) -> Bool
  return Tables.ruby_synonyms().any? do |known: String| known == key end
end
