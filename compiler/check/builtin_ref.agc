## A function reference to a builtin: `&Time.now_ms` (a function) or `&Int.to_s` (a method, whose receiver is the first
## parameter). The checker gives it the Fn type of the builtin's one signature. The value is a small function of the
## compiler prelude (prelude_files.agc) that calls the builtin, which the checker writes as text and checks like any
## prelude function, so the call goes through the usual rules and lowering.
##
## Only a public builtin with one form, the plain rule and parameter types a program can write can be a value. Any
## other is refused with a help that names the block to write instead.

import Model from "../catalog/builtin_model"
import {ENTRIES, PUBLIC_NAMES} from "../catalog/builtins"
import T from "../syntax/types"
import RubyForm from "ruby_form"
import Tables from "check_tables"

## The prelude file stem of the wrappers: no file of stdlib/prelude/ has this name.
export REFS_MODULE = "builtin_refs"

BLOCK_HELP = "pass a block that calls it instead, such as do |x| ... end, or wrap it in a def"

## A builtin a reference names: the builtin, and the method it is written with (`to_s` for `&Int.to_s`), or "" for a
## function (`&Time.now_ms`).
export struct Ref
  builtin: Model.Builtin
  method: String
end

## What a name after `&` is when no function of the program has it.
export enum Found
  ## No builtin has the name.
  Missing
  ## A builtin that cannot be a value, with the help to show.
  Refused(String)
  Builtin(Ref)
end

## The builtin that `&name` names, as written in the program (`Int.to_s`, `Time.now_ms`, `puts`).
export def find(name: String) -> Found
  parts = name.split(".")
  aliased = Tables.method_aliases().get(name)
  if parts.size == 2 and aliased.some? and PUBLIC_NAMES.include?(aliased.unwrap!)
    return usable(ENTRIES[aliased.unwrap!], name, parts[1])
  end

  entry = ENTRIES.get(name)
  if parts.size == 2 and (entry.none? or !PUBLIC_NAMES.include?(name))
    # A method of a kind whose builtins live in another module: `&Json.get` is JSON.get.
    for candidate in PUBLIC_NAMES
      if candidate.end_with?(".#{parts[1]}") and RubyForm.method_key(candidate) == name
        return usable(ENTRIES[candidate], name, parts[1])
      end
    end
  end

  return Found.Missing if entry.none? or !PUBLIC_NAMES.include?(name)

  # A function of a family member (OpenSSL.Digest.sha256): the prelude file is not linked, so it cannot call one.
  return Found.Refused(BLOCK_HELP) if parts.size == 3

  key = RubyForm.method_key(name)
  return usable(entry.unwrap!, name, parts[1]) if key == name

  return Found.Refused("write it as Ruby does: &#{key}") if key != ""

  usable(entry.unwrap!, name, "")
end

## The Fn type of the reference: the builtin's parameters, the receiver first, and its result.
export def fn_type(ref: Ref) -> T.Type
  T.Type.Fn(ref.builtin.parameters.map do |parameter: Model.Named| parameter.type end, ref.builtin.result)
end

## The source of the prelude file with one function per reference, in order: `ref_0` calls the builtin of `names[0]`.
export def source(names: List[String]) -> String
  functions: List[String] = []
  for name in names
    case find(name)
      Found.Builtin(ref) -> functions = functions.push(wrapper("ref_#{functions.size}", name, ref))
      _ -> functions = functions.push("")
    end
  end

  functions.join("\n")
end

# `def ref_N(p0: Int) -> String` and a body that calls the builtin with the parameters: `p0.to_s()` for a method,
# `Time.now_ms()` for a function.
def wrapper(function: String, name: String, ref: Ref) -> String
  params: List[String] = []
  args: List[String] = []
  for parameter in ref.builtin.parameters
    params = params.push("p#{args.size}: #{T.to_text(parameter.type)}")
    args = args.push("p#{args.size}")
  end

  call = "#{name}(#{args.join(", ")})"
  if ref.method != ""
    call = "p0.#{ref.method}(#{args.drop(1).join(", ")})"
  end

  "def #{function}(#{params.join(", ")}) -> #{T.to_text(ref.builtin.result)}\n  #{call}\nend\n"
end

# The builtin as a reference when it can be one: one form, the plain rule, and types a program can write.
def usable(entry: Model.Builtin, name: String, method: String) -> Found
  params = entry.parameters.map do |parameter: Model.Named| parameter.type end
  types = params.push(entry.result)
  if entry.alternatives.size > 0 or !plain?(entry.rule) or !types.all? do |type: T.Type| writable?(type) end
    return Found.Refused(BLOCK_HELP)
  end

  Found.Builtin(Ref(builtin: entry, method: method))
end

def plain?(rule: Model.Rule) -> Bool
  case rule
    Model.Rule.Plain -> true
    _ -> false
  end
end

# True when the prelude file can write the type: an opaque type of one word (FileHandle), no task, channel or lazy
# value, and no type variable (no generic builtin has the plain rule).
def writable?(type: T.Type) -> Bool
  case type
    T.Type.Opaque(name) -> !name.include?(".")
    T.Type.Task(_) -> false
    T.Type.Channel(_) -> false
    T.Type.Lazy(_) -> false
    T.Type.Codec(_) -> false
    T.Type.ATS(_, _) -> false
    T.Type.Unknown -> false
    T.Type.Var(_) -> false
    T.Type.Struct(name, args) -> !name.include?("@") and args.all? do |arg: T.Type| writable?(arg) end
    T.Type.Enum(name, args) -> !name.include?("@") and args.all? do |arg: T.Type| writable?(arg) end
    T.Type.Result(item) -> writable?(item)
    T.Type.Optional(item) -> writable?(item)
    T.Type.List(item) -> writable?(item)
    T.Type.Set(item) -> writable?(item)
    T.Type.Map(key, value) -> writable?(key) and writable?(value)
    T.Type.Fn(params, result) -> writable?(result) and params.all? do |param: T.Type| writable?(param) end
    _ -> true
  end
end
