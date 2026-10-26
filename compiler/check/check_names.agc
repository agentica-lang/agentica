## Which builtin a method name stands for. A receiver kind is the word of its type ("String", "List",
## ...); "" is no kind. A method is resolved to the full name of a builtin, such as String.length, or to "self" when it
## returns the receiver (to_s on a String).

import {ENTRIES} from "../catalog/builtins"
import RubyForm from "ruby_form"
import T from "../syntax/types"
import State from "check_state"

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
    word == "Channel" or
    word == "Lazy"
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

## The methods a receiver kind has, as Ruby names them: its aliases and the builtins of its module, without
## duplicates. A builtin that has a Ruby name (`strip`) is listed under it, not under its own (`trim`), which still
## works; a synonym (`collect` for `map`, `size` for `String.length`) is accepted but not listed.
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
    if !seen.include?(name) and ruby_method?(cx, kind, name) and !RubyForm.synonym?("#{kind}.#{name}")
      seen = seen.add(name)
      unique = unique.push(name)
    end
  end

  return unique
end

## The method name a builtin is written as in method form, for the help of CHECK-PIPE-METHOD: String.upcase is upcase,
## String.trim is strip. "" when there is none for that kind.
export def pipe_method_name(cx: State.Cx, kind: String, name: String) -> String
  if RubyForm.method_key(name).starts_with?("#{kind}.")
    return RubyForm.method_name(name)
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
  elsif (kind == "List" or kind == "Range") and lazy_step?(name) and resolve_method(cx, "List", name) == ""
    receiver = "xs"
    if kind == "Range"
      receiver = "(a..b)"
    end

    return "#{kind} methods are eager; #{name} is a step of Lazy: call .lazy first: #{receiver}.lazy.#{name}(...)"
  elsif kind == "Lazy" and catalog_method(cx, "List", name) != ""
    return "a Lazy runs only in a terminal; collect it first with try lz.to_a (or lz.first(n)), then call .#{name}"
  end

  return renamed_help(cx, kind, name)
end

# True when Lazy has a step with that name: a method that takes a Lazy and returns one (not the source produce).
def lazy_step?(name: String) -> Bool
  entry = ENTRIES.get("Lazy.#{name}")
  if !entry.ok?
    return false
  end

  row = entry.unwrap!
  return T.is?(row.result, "Lazy") and row.parameters.size > 0 and T.is?(row.parameters[0].type, "Lazy")
end

# The builtin of the kind's module with that name whose first parameter has the kind, or "".
def catalog_method(cx: State.Cx, kind: String, name: String) -> String
  module = cx.help.modules.get(kind)
  if !module.ok?
    return ""
  end

  entry = ENTRIES.get("#{module.unwrap!}.#{name}")
  if entry.ok? and entry.unwrap!.parameters.size > 0 and T.tag(entry.unwrap!.parameters[0].type) == kind
    return entry.unwrap!.name
  end

  return ""
end

# The names of the module's builtins that are methods of the kind.
def module_methods(cx: State.Cx, kind: String, prefix: String) -> List[String]
  names: List[String] = []
  for key in ENTRIES.keys
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

# True when `name` is a Ruby name of the method it resolves to (`strip`, not `trim`), or has no builtin (`to_s`).
def ruby_method?(cx: State.Cx, kind: String, name: String) -> Bool
  resolved = resolve_method(cx, kind, name)
  return RubyForm.method_name(resolved) == "" or RubyForm.ruby_name?(kind, name, resolved)
end

# A method another language names differently: the Ruby names of the methods of that kind that it stands for, if
# there are any (`len` is `.length` or `.size` on a String).
def renamed_help(cx: State.Cx, kind: String, name: String) -> String
  candidates = cx.help.foreign_methods.get(name)
  if !candidates.ok?
    return ""
  end

  found: List[String] = []
  for candidate in candidates.unwrap!
    resolved = resolve_method(cx, kind, candidate)
    if resolved != ""
      written = RubyForm.method_name(resolved)
      if written == "" or RubyForm.ruby_name?(kind, candidate, resolved)
        written = candidate
      end

      found = found.push(written)
    end
  end

  if found.size == 0
    return ""
  end

  return "use #{found.uniq.map do |written: String| ".#{written}" end.join(" or ")}"
end
