## The builtins that a name from another language stands for, for `agentica help`: `strip` and `String.strip` are
## `String.trim` (which `help` writes in its Ruby form, `s.strip()`), `len` is `size` or `length` of each type that has
## one, `value!` is `Result.unwrap!`. The names come from the tables the checker already keeps for its "did you mean"
## help (check_tables.agc), plus every public builtin whose method name (the part after the dot) is the name asked.

import {PUBLIC_NAMES} from "../catalog/builtins"
import CatalogJson from "../catalog/catalog_json"
import RubyForm from "../check/ruby_form"
import Tables from "../check/check_tables"

# A name that stands for more builtins than this is too vague to list (`new`, `read`).
MAX_TARGETS = 8

## The public builtins that `name` stands for, sorted, or an empty list. `name` is a method name (`strip`) or a
## receiver kind and a method name (`String.strip`); with a kind only the builtins of that kind count. A name that is
## itself a public builtin is not asked here.
export def targets(name: String) -> List[String]
  parts = name.split(".")
  modules = Tables.method_modules()
  kind = ""
  method = name
  if parts.size == 2 and modules.has_key?(parts[0])
    kind = parts[0]
    method = parts[1]
  elsif parts.size != 1
    return []
  end

  found = from_aliases(method, kind)
    .concat(from_renamed(method, kind, modules))
    .concat(from_method_names(method, kind, modules))
  public = found.uniq.sort.filter do |target: String| CatalogJson.public(target).ok? end
  if public.size > MAX_TARGETS
    return []
  end

  # The builtins written as a method of that name come first: `join` is the join of a List before `Path.join`.
  written = public.filter do |target: String| RubyForm.written_as?(target, method) end
  return written.concat(public.filter do |target: String| !RubyForm.written_as?(target, method) end)
end

## The checker's hints for the methods that a bare `name` is on some type (`List.contains: a List has no ...`), by
## `Kind.name`. A name with a dot has none: its own hint is looked up whole.
export def kind_hints(name: String) -> Map[String, String]
  hints = Tables.foreign_kind_methods()
  found: Map[String, String] = {}
  if name.contains?(".")
    return found
  end

  for key in hints.keys.sort
    if key.ends_with?(".#{name}")
      found = found.put(key, hints[key])
    end
  end

  return found
end

# The method aliases of the checker: `String.strip` is `String.trim`. `self` (`String.to_s`) is no builtin.
def from_aliases(method: String, kind: String) -> List[String]
  aliases = Tables.method_aliases()
  found: List[String] = []
  for key in aliases.keys.sort
    pieces = key.split(".")
    target = aliases[key]
    if pieces[1] == method and (kind == "" or pieces[0] == kind) and target != "self"
      found = found.push(target)
    end
  end

  return found
end

# The foreign method names of the checker: `len` is `size` or `length`, in each module that has one.
def from_renamed(method: String, kind: String, modules: Map[String, String]) -> List[String]
  renamed = Tables.foreign_methods().get(method)
  if !renamed.ok?
    return []
  end

  aliases = Tables.method_aliases()
  found: List[String] = []
  for receiver in modules.keys.sort
    if kind == "" or receiver == kind
      for candidate in renamed.unwrap!
        alias = aliases.get("#{receiver}.#{candidate}")
        if alias.ok?
          found = found.push(alias.unwrap!)
        else
          found = found.push("#{modules[receiver]}.#{candidate}")
        end
      end
    end
  end

  return found
end

# The builtins whose method name is `method`: `trim` is `String.trim`.
def from_method_names(method: String, kind: String, modules: Map[String, String]) -> List[String]
  ending = ".#{method}"
  found: List[String] = []
  for candidate in PUBLIC_NAMES.sort
    if candidate.ends_with?(ending) and (kind == "" or candidate.starts_with?("#{modules[kind]}."))
      found = found.push(candidate)
    end
  end

  return found
end
