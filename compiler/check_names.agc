## Which builtin a method name stands for. A receiver kind is the word of its type ("String", "List",
## ...); "" is no kind. A method is resolved to the full name of a builtin, such as String.length, or to "self" when it
## returns the receiver (to_s on a String).

import State from "check_state"
import T from "types"

## The kind of a receiver, or "" when its type has no methods in the catalog.
export def receiver_kind(type: T.Type) -> String
  word = T.tag(type)
  if (
    word == "String" or
    word == "List" or
    word == "Map" or
    word == "Set" or
    word == "Float" or
    word == "Result" or
    word == "Json" or
    word == "Int" or
    word == "Range" or
    word == "Channel"
  )
    return word
  end
  return ""
end

## The builtin that method name of that kind stands for, "self", or "" when there is none: an alias first (size, to_i,
## push), then the builtin of the kind's module whose first parameter has that kind.
export def resolve_method(cx: State.Cx, kind: String, name: String) -> String
  alias = cx.help.aliases.get("#{kind}.#{name}")
  if alias.ok?
    return alias.unwrap!
  end
  return catalog_method(cx, kind, name)
end

## The methods a receiver kind has: its aliases and the builtins of its module, without duplicates.
export def method_names(cx: State.Cx, kind: String) -> List[String]
  names: List[String] = []
  seen: Set[String] = Set.new([])
  prefix = "#{kind}."
  for key in cx.help.aliases.keys
    if key.starts_with?(prefix)
      names = names.push(key.slice(prefix.length, key.length - prefix.length))
    end
  end
  module = cx.help.modules.get(kind)
  if module.ok?
    names = names.concat(module_methods(cx, kind, "#{module.unwrap!}."))
  end
  unique: List[String] = []
  for name in names
    if !seen.include?(name)
      seen = seen.add(name)
      unique = unique.push(name)
    end
  end
  return unique
end

## The method name a builtin is written as in method form, for the help of CHECK-PIPE-METHOD: String.upcase is upcase,
## String.to_int is the alias to_i. "" when there is none.
export def pipe_method_name(cx: State.Cx, kind: String, name: String) -> String
  dot = name.index_of(".")
  if dot.ok?
    suffix = name.slice(dot.unwrap! + 1, name.length - dot.unwrap! - 1)
    if resolve_method(cx, kind, suffix) == name
      return suffix
    end
  end
  prefix = "#{kind}."
  for key in cx.help.aliases.keys.sort
    if key.starts_with?(prefix) and cx.help.aliases[key] == name
      return key.slice(prefix.length, key.length - prefix.length)
    end
  end
  return ""
end

## The help for a method name another language has, or "".
export def foreign_method_help(cx: State.Cx, kind: String, name: String) -> String
  direct = cx.help.kind_methods.get("#{kind}.#{name}")
  if direct.ok?
    return direct.unwrap!
  end
  if kind == "Result" and string_method?(cx, name)
    return result_help(cx, name)
  elsif name == "nil?"
    return "values are never nil unless their type is Nil; compare with nil: x == nil"
  elsif name == "lazy" and (kind == "List" or kind == "Range")
    return "lists are eager; read a source that is too big for a list in a while loop"
  end
  return renamed_help(cx, kind, name)
end

# The builtin of the kind's module with that name whose first parameter has the kind, or "".
def catalog_method(cx: State.Cx, kind: String, name: String) -> String
  module = cx.help.modules.get(kind)
  if !module.ok?
    return ""
  end
  entry = cx.catalog.entries.get("#{module.unwrap!}.#{name}")
  if entry.ok? and entry.unwrap!.parameters.size > 0 and T.tag(entry.unwrap!.parameters[0].type) == kind
    return entry.unwrap!.name
  end
  return ""
end

# The names of the module's builtins that are methods of the kind.
def module_methods(cx: State.Cx, kind: String, prefix: String) -> List[String]
  names: List[String] = []
  for key in cx.catalog.entries.keys
    if key.starts_with?(prefix)
      name = key.slice(prefix.length, key.length - prefix.length)
      if catalog_method(cx, kind, name) != ""
        names = names.push(name)
      end
    end
  end
  return names
end

# True when a String has the method, or a foreign String method has help.
def string_method?(cx: State.Cx, name: String) -> Bool
  return resolve_method(cx, "String", name) != "" or cx.help.kind_methods.has_key?("String.#{name}")
end

# A method of a String that a Result does not have: unwrap the Result first.
def result_help(cx: State.Cx, name: String) -> String
  string_help = foreign_method_help(cx, "String", name)
  text = "this is a Result; unwrap it first with r.unwrap! (use gets! to read a line without a Result)"
  if string_help != ""
    return "#{text}, then: #{string_help}"
  end
  return text
end

# A method another language names differently: the Agentica method of that kind, if there is one.
def renamed_help(cx: State.Cx, kind: String, name: String) -> String
  candidates = cx.help.foreign_methods.get(name)
  if !candidates.ok?
    return ""
  end
  for candidate in candidates.unwrap!
    if resolve_method(cx, kind, candidate) != ""
      return "use .#{candidate}"
    end
  end
  return ""
end
