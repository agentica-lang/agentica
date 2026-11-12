## Which builtin a method name stands for. A receiver kind is the word of its type ("String", "List",
## ...); "" is no kind. A method is resolved to the full name of a builtin, such as String.length, or to "self" when it
## returns the receiver (to_s on a String).

import {ENTRIES, OPERATOR_ONLY} from "../catalog/builtins"
import RubyForm from "ruby_form"
import T from "../syntax/types"
import State from "check_state"

## The receiver kinds: the words of the types whose values have methods in the catalog, and Mutex (a parameter kind of
## RubyForm). Infer reads them all to ask which receivers have a method of some name.
export METHOD_KINDS = [
  "String",
  "List",
  "Map",
  "Set",
  "Float",
  "Result",
  "Optional",
  "Json",
  "Int",
  "Range",
  "Bytes",
  "Channel",
  "Address",
  "Lazy",
  "Codec",
  "ATS",
  "Task",
  "Mutex",
]

## The kind of a receiver, or "" when its type has no methods in the catalog.
export def receiver_kind(type: T.Type) -> String
  word = T.tag(type)
  if word == "Opaque" and T.name(type) == "TaskRef"
    # The running task (Task.current) has the methods of a task.
    return "Task"
  end

  return "Mutex" if RubyForm.parameter_kind(type) == "Mutex"

  # No tag is "Mutex", so only the words of the tags match here.
  return word if METHOD_KINDS.include?(word)

  ""
end

## The builtin that method name of that kind stands for, "self", or "" when there is none: an alias first (size, to_i,
## push), then the builtin of the kind's module whose first parameter has that kind.
export def resolve_method(cx: State.Cx, kind: String, name: String) -> String
  alias = cx.help.aliases.get("#{kind}.#{name}")
  return alias.unwrap! if alias.some?

  catalog_method(cx, kind, name)
end

## The methods a receiver kind has, as Ruby names them: its aliases and the builtins of its module, without
## duplicates. A builtin that has a Ruby name (`select`) is listed under it, not under its own (`filter`), which still
## works; a synonym (`collect` for `map`, `size` for `String.length`) is accepted but not listed.
export def method_names(cx: State.Cx, kind: String) -> List[String]
  names: List[String] = []
  seen: Set[String] = Set.new([])
  prefix = "#{kind}."
  for key in cx.help.aliases.keys
    if key.start_with?(prefix)
      names = names.push(key.slice(prefix.length, key.length - prefix.length))
    end
  end

  module = cx.help.modules.get(kind)
  if module.some?
    names = names.concat(module_methods(cx, kind, "#{module.unwrap!}."))
  end

  unique: List[String] = []
  for name in names
    if !seen.include?(name) and ruby_method?(cx, kind, name) and !RubyForm.synonym?("#{kind}.#{name}")
      seen = seen.add(name)
      unique = unique.push(name)
    end
  end

  unique
end

## The method name a builtin is written as in method form, for the help of CHECK-PIPE-METHOD: String.upcase is upcase,
## List.filter is select. "" when there is none for that kind.
export def pipe_method_name(cx: State.Cx, kind: String, name: String) -> String
  return RubyForm.method_name(name) if RubyForm.method_key(name).start_with?("#{kind}.")

  ""
end

## The help for a method name another language has, or "".
export def foreign_method_help(cx: State.Cx, kind: String, name: String) -> String
  direct = cx.help.kind_methods.get("#{kind}.#{name}")
  return direct.unwrap! if direct.some?

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
  elsif kind == "Lazy" and shown_method(cx, "List", name) != ""
    return "a Lazy runs only in a terminal; collect it first with try lz.to_a (or lz.first(n)), then call .#{name}"
  end

  renamed_help(cx, kind, name)
end

# True when Lazy has a step with that name: a method that takes a Lazy and returns one (not the source produce).
def lazy_step?(name: String) -> Bool
  entry = ENTRIES.get("Lazy.#{name}")
  return false if entry.none?

  row = entry.unwrap!
  T.is?(row.result, "Lazy") and row.parameters.size > 0 and T.is?(row.parameters[0].type, "Lazy")
end

# The builtin of the kind's module with that name whose first parameter has the kind, or "".
def catalog_method(cx: State.Cx, kind: String, name: String) -> String
  module = cx.help.modules.get(kind)
  return "" if module.none?

  entry = ENTRIES.get("#{module.unwrap!}.#{name}")
  return "" if entry.none? or entry.unwrap!.parameters.size == 0

  return entry.unwrap!.name if RubyForm.parameter_kind(entry.unwrap!.parameters[0].type) == kind

  ""
end

# A method that a help may offer: catalog_method, less a builtin written as an operator (List.concat is `+`), which
# still resolves in a call but no text shows.
def shown_method(cx: State.Cx, kind: String, name: String) -> String
  found = catalog_method(cx, kind, name)
  return "" if OPERATOR_ONLY.include?(found)

  found
end

# The names of the module's builtins that are methods of the kind, as a help offers them.
def module_methods(cx: State.Cx, kind: String, prefix: String) -> List[String]
  names: List[String] = []
  for key in ENTRIES.keys
    if key.start_with?(prefix)
      name = key.slice(prefix.length, key.length - prefix.length)
      if shown_method(cx, kind, name) != ""
        names = names.push(name)
      end
    end
  end

  names
end

# True when a String has the method, or a foreign String method has help.
def string_method?(cx: State.Cx, name: String) -> Bool
  resolve_method(cx, "String", name) != "" or cx.help.kind_methods.has_key?("String.#{name}")
end

# A method of a String that a Result does not have: unwrap the Result first.
def result_help(cx: State.Cx, name: String) -> String
  string_help = foreign_method_help(cx, "String", name)
  text = "this is a Result; unwrap it first with r.unwrap! (use gets! to read a line without a Result)"
  return "#{text}, then: #{string_help}" if string_help != ""

  text
end

# True when `name` is a Ruby name of the method it resolves to (`select`, not `filter`), or has no builtin (`to_s`).
def ruby_method?(cx: State.Cx, kind: String, name: String) -> Bool
  resolved = resolve_method(cx, kind, name)
  RubyForm.method_name(resolved) == "" or RubyForm.ruby_name?(kind, name, resolved)
end

# A method another language names differently: the Ruby names of the methods of that kind that it stands for, if
# there are any (`len` is `.length` or `.size` on a String).
def renamed_help(cx: State.Cx, kind: String, name: String) -> String
  candidates = cx.help.foreign_methods.get(name)
  return "" if candidates.none?

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

  return "" if found.size == 0

  methods = found.uniq.map do |written: String| ".#{written}" end
  "use #{methods.join(" or ")}"
end
