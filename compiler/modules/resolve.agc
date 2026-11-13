## Name resolution of the linker: what a name written in one file is called in the linked program.
##
## A name declared in the root file keeps its name; a name declared in another file gets the prefix of that file
## ("@2::"), so equal names of two files stay apart. A name through an import alias (Alias.name) becomes the prefixed
## name in the imported file, if that file exports it; a name that file re-exports is the name in the file that
## declares it.

import Builtins from "../catalog/builtins"
import {BARE_NAMES, ENUMS, ENTRIES, FAMILY_MEMBERS, RECORDS, RESERVED, STD_ONLY} from "../catalog/builtins"
import Diag from "../diagnostics/diagnostic"
import Base from "../syntax/parse_base"
import Source from "../syntax/source"
import Suggest from "../syntax/suggest"
import T from "../syntax/types"
import Declarations from "declarations"
import ImportHelp from "import_help"
import Env from "link_env"
import Failure from "link_failure"
import Modules from "modules"
import Resolve from "resolve_import"

# The builtin types with a module name that is no family, which any file may name: C.Pointer, the type of a C pointer
# (the extern blocks of native code), Native.Mutex, the lock of a native library, and Process.Options, the options of
# the spawns. The types of a family are family_member's.
MODULE_TYPES = Set.new(["C.Pointer", "Native.Mutex", "Process.Options"])

## What the linker knows while it rewrites one file: the settings, every module, the file itself, the linked names of
## the user structs the file may update (StructUpdate.visible), and ids, the number of node ids of the program (the
## receiver of a rewritten NAME.method(...) takes the id ids + the id of the call). type_parameters are the type
## parameters of the generic function being rewritten, whose names stay as written.
export struct Context
  settings: Env.Settings
  modules: Map[String, Modules.Module]
  me: Modules.Module
  visible: List[String]
  ids: Int
  type_parameters: List[String]
end

## What a name must be where it is written: a type (a struct, enum or alias), an enum, or a function.
export enum Want
  Type
  Enum
  Function
end

## The name in the linked program for a name written in the file. want says what the name must be. hint adds the enum
## hint to the help of an unknown alias. A failure is CHECK-IMPORT-NAME, CHECK-TYPE-MISMATCH or CHECK-UNKNOWN-NAME at
## span.
export def resolve(cx: Context, name: String, want: Want, span: Source.Span, hint: Bool) -> Result[String]
  parts = name.split(".")
  if parts.size == 2
    return qualified(cx, parts[0], parts[1], want, span, hint)
  elsif parts.size == 3 and family?(cx, parts[0])
    return member_function(cx, parts, want, span)
  elsif parts.size == 3 and aliased_block(cx, parts[0], parts[1]) != ""
    return imported(cx, cx.modules[aliased_block(cx, parts[0], parts[1])], parts[2], want, span)
  end

  return imported_by_name(cx, cx.me.named[name], want, span) if cx.me.named.has_key?(name)

  return ok(name) if builtin_name?(cx, name, want)

  ok(cx.me.prefix + name)
end

## The linked name of a type written with `arity` type arguments, as resolve with Want.Type. Address[M] is always the
## builtin, as in the checker (check_types.agc): Address is not reserved, since a program's own `struct Address` is
## common.
export def resolve_type(cx: Context, name: String, arity: Int, span: Source.Span) -> Result[String]
  return ok(name) if name == "Address" and arity == 1

  resolve(cx, name, Want.Type, span, false)
end

## True when the name is a builtin family (OpenSSL) in this file: its members are written Family.Member. An import
## alias of the same name wins, though a family name is reserved, so only std/ internals could take one.
export def family?(cx: Context, name: String) -> Bool = FAMILY_MEMBERS.has_key?(name) and !cx.me.aliases.has_key?(name)

## True when the file declares an enum with this name.
export def local_enum?(cx: Context, name: String) -> Bool
  cx.me.names.has_key?(name) and Declarations.enum?(cx.me.names[name])
end

## True when the module exports an enum with this name.
export def exports_enum?(module: Modules.Module, name: String) -> Bool
  module.public.has_key?(name) and Declarations.enum?(module.public[name])
end

## True when the file imports an enum by name under this name (or, in a module block, sees one of its file).
export def named_enum?(cx: Context, name: String) -> Bool
  cx.me.named.has_key?(name) and Declarations.enum?(named_kind(cx, cx.me.named[name]))
end

## The key of the module block `block` that the module under the import alias `alias` exports (`Alias.Block.name`),
## or "".
export def aliased_block(cx: Context, alias: String, block: String) -> String
  return "" if !cx.me.aliases.has_key?(alias)

  Modules.exported_block(cx.modules[cx.me.aliases[alias]], block)
end

## The linked name of the constant that a name reads in this file (declared here, or imported by name), or "" when the
## name is not a constant of the file.
export def constant_identity(cx: Context, name: String) -> String
  return identity(cx, name) if cx.me.names.has_key?(name) and Declarations.constant?(cx.me.names[name])

  if cx.me.named.has_key?(name)
    entry = cx.me.named[name]
    target = cx.modules[entry.target]
    return Modules.linked_name(cx.modules, target, entry.name) if Declarations.constant?(named_kind(cx, entry))
  end

  ""
end

## The linked name of the constant that Alias.NAME reads, or "" when the alias is unknown or the module it names does
## not export a constant of that name (a private constant is left to `resolve`, which refuses it like a private
## function).
export def alias_constant_identity(cx: Context, name: String) -> String
  # An alias is a single segment, so only `Alias.NAME` counts, and `Alias.Block.NAME` for a module block it exports.
  parts = name.split(".")
  key = ""
  if parts.size == 2 and cx.me.aliases.has_key?(parts[0])
    key = cx.me.aliases[parts[0]]
  elsif parts.size == 3
    key = aliased_block(cx, parts[0], parts[1])
  end

  return "" if key == ""

  target = cx.modules[key]
  member = parts[parts.size - 1]
  if target.public.has_key?(member) and Declarations.constant?(target.public[member])
    return Modules.linked_name(cx.modules, target, member)
  end

  ""
end

## True when the name is a type that the file declares or imports by name (a struct, enum, type alias or resource), or
## a builtin record such as File.Info.
export def declared_type?(cx: Context, name: String) -> Bool
  return right_kind?(cx.me.names[name], Want.Type) if cx.me.names.has_key?(name)

  return right_kind?(named_kind(cx, cx.me.named[name]), Want.Type) if cx.me.named.has_key?(name)

  RECORDS.has_key?(name)
end

## A name in capitals that no declaration, import, alias or reserved type of the file owns: a constant that does not
## exist.
export def unknown_constant?(cx: Context, name: String) -> Bool
  (
    Base.constant_name?(name) and
    !RESERVED.include?(name) and
    !cx.me.names.has_key?(name) and
    !cx.me.named.has_key?(name) and
    !cx.me.aliases.has_key?(name)
  )
end

## CHECK-UNKNOWN-NAME for such a name, with the closest constant the file can read: its own, declared above or below,
## and the ones it imports by name, by the name written.
export def unknown_constant_failure(cx: Context, name: String, span: Source.Span) -> String
  seen: List[String] = []
  for own in cx.me.names.keys
    if Declarations.constant?(cx.me.names[own])
      seen = seen.push(own)
    end
  end

  for local in cx.me.named.keys
    if Declarations.constant?(named_kind(cx, cx.me.named[local]))
      seen = seen.push(local)
    end
  end

  help = Diag.Help.NoHelp
  case Suggest.did_you_mean_among(name, [], seen)
    some(text) -> help = Failure.hint(text)
    none -> help = Diag.Help.NoHelp
  end

  Failure.fail_at(site(cx, span), "CHECK-UNKNOWN-NAME", "unknown name \"#{name}\"", help)
end

## The kind of what a name of the `named` table stands for.
export def named_kind(cx: Context, entry: Modules.Named) -> Declarations.Kind
  Modules.kind_in(cx.modules[entry.target], entry.name)
end

## The name in the linked program of a declaration of the file.
export def identity(cx: Context, name: String) -> String = cx.me.prefix + name

# A reserved type, a builtin enum (and Result and Optional), or a bare builtin function keeps its name.
def builtin_name?(cx: Context, name: String, want: Want) -> Bool
  case want
    Want.Type -> RESERVED.include?(name)
    Want.Enum -> name == "Result" or name == "Optional" or ENUMS.has_key?(name)
    Want.Function -> BARE_NAMES.include?(name)
  end
end

def site(cx: Context, span: Source.Span) -> Failure.Site = Failure.Site(file: cx.me.file, span: span)

# Alias.member: through an import, or a builtin module call that the checker will judge.
def qualified(cx: Context, alias: String, member: String, want: Want, span: Source.Span, hint: Bool) -> Result[String]
  target = cx.me.aliases.get(alias, "")
  if target != ""
    return imported(cx, cx.modules[target], member, want, span)
  elsif STD_ONLY.has_key?(alias) and !Resolve.embedded?(cx.me.key)
    return error(std_only_failure(cx, alias, member, want, span))
  elsif family?(cx, alias) and !(alias == "JSON" and member == "Codec")
    return family_member(cx, alias, member, want, span)
  elsif function_wanted?(want) or std_record?(alias, member, want) or builtin_type?(alias, member, want)
    return ok("#{alias}.#{member}")
  end

  message = "unknown module alias"
  if alias == "JSON" and member == "Codec"
    message = "JSON.Codec no longer exists"
  end

  error(Failure.fail_at(site(cx, span), "CHECK-IMPORT-NAME", message, Failure.hint(alias_help(alias, member, hint))))
end

# Family.Member: a builtin type of the family where a type or an enum is wanted (JSON.Field), or a function of the
# family itself (Family.fn). A member that is a group of functions is no type or enum (CHECK-UNKNOWN-TYPE); a name
# that is no member is CHECK-UNKNOWN-NAME with the members in the help.
def family_member(cx: Context, family: String, member: String, want: Want, span: Source.Span) -> Result[String]
  name = "#{family}.#{member}"
  if function_wanted?(want) and (ENTRIES.has_key?(name) or Builtins.member?(family, member))
    # A member called as a function is an unknown function for the checker, with the closest name.
    return ok(name)
  elsif function_wanted?(want) and own_functions?(family) and member_owners(family, member).size == 0
    # File.reed: the checker gives the unknown function with the closest one (File.read).
    return ok(name)
  elsif type_wanted?(want) and Builtins.member_type?(family, member)
    return ok(name)
  elsif enum_wanted?(want) and Builtins.member_type?(family, member)
    # JSON.Field, or a type of the family that is no enum (File.Info.Foo), which the checker reports as for any type.
    return ok(name)
  elsif !function_wanted?(want) and Builtins.member?(family, member)
    return error(not_a_type(cx, name, name, span))
  end

  error(unknown_member(cx, family, member, span))
end

# Family.Member.fn: the builtin function of a member, which the checker judges (an unknown fn there is an unknown
# function with the closest name). A member the family lacks is CHECK-UNKNOWN-NAME here.
def member_function(cx: Context, parts: List[String], want: Want, span: Source.Span) -> Result[String]
  return error(unknown_member(cx, parts[0], parts[1], span)) if !Builtins.member?(parts[0], parts[1])

  name = parts.join(".")
  return error(not_a_type(cx, name, "#{parts[0]}.#{parts[1]}", span)) if !function_wanted?(want)

  ok(name)
end

# CHECK-UNKNOWN-TYPE for a name of a family that is no type, where member is the group of functions it names.
def not_a_type(cx: Context, name: String, member: String, span: Source.Span) -> String
  help = "#{member} is a group of functions, such as #{first_function(member)}"
  Failure.fail_at(site(cx, span), "CHECK-UNKNOWN-TYPE", "#{name} is not a type", Failure.hint(help))
end

# CHECK-UNKNOWN-NAME for Family.name when the family has no such member: the closest member, a member whose function
# has the name (OpenSSL.sha256 is OpenSSL.Digest.sha256), and the list of the members.
def unknown_member(cx: Context, family: String, member: String, span: Source.Span) -> String
  members = FAMILY_MEMBERS[family]
  help = "the members of #{family} are #{members.join(", ")}"
  owners = member_owners(family, member)
  if owners.size > 0
    help = "use #{family}.#{owners[0]}.#{member}; #{help}"
  else
    case Suggest.closest_among(member, [], members)
      some(found) -> help = "did you mean \"#{family}.#{found}\"? #{help}"
      none -> help = help
    end
  end

  Failure.fail_at(site(cx, span), "CHECK-UNKNOWN-NAME", "#{family} has no member \"#{member}\"", Failure.hint(help))
end

# The members of the family that have a function of this name (OpenSSL.Digest for sha256).
def member_owners(family: String, name: String) -> List[String]
  FAMILY_MEMBERS[family].filter do |owner: String| ENTRIES.has_key?("#{family}.#{owner}.#{name}") end
end

# True when the family has functions of its own, written Family.fn (File.read, JSON.parse).
def own_functions?(family: String) -> Bool
  ENTRIES.keys.any? do |name: String| name.start_with?("#{family}.") and name.split(".").size == 2 end
end

# The first function, by name, of a member that is a group of functions: an example for a help.
def first_function(member: String) -> String
  found = ENTRIES.keys.filter do |name: String| name.start_with?("#{member}.") end
  return "#{member}.fn" if found.size == 0

  found.sort[0]
end

# A builtin record, enum or opaque type of a std-only module, such as HttpWire.Head, LogRegistry.Level or
# HttpWire.Client: a type that only std/ can name, so it reserves no name in user programs (the std/ module may
# re-export it).
def std_record?(alias: String, member: String, want: Want) -> Bool
  name = "#{alias}.#{member}"
  case want
    Want.Type -> STD_ONLY.has_key?(alias) and Builtins.type_named?(name)
    Want.Enum -> STD_ONLY.has_key?(alias) and ENUMS.has_key?(name)
    Want.Function -> false
  end
end

# True for one of MODULE_TYPES where a type is wanted.
def builtin_type?(alias: String, member: String, want: Want) -> Bool
  case want
    Want.Type -> MODULE_TYPES.include?("#{alias}.#{member}")
    _ -> false
  end
end

def type_wanted?(want: Want) -> Bool
  case want
    Want.Type -> true
    _ -> false
  end
end

def enum_wanted?(want: Want) -> Bool
  case want
    Want.Enum -> true
    _ -> false
  end
end

def function_wanted?(want: Want) -> Bool
  case want
    Want.Function -> true
    _ -> false
  end
end

# Family.member of a std-only family outside std/: CHECK-UNKNOWN-NAME named for what the position wants, with the std
# module to import, and the written name when std/ re-exports the member (HttpWire.Client is HTTP.Client).
def std_only_failure(cx: Context, alias: String, member: String, want: Want, span: Source.Span) -> String
  name = "#{alias}.#{member}"
  help = Modules.std_only_help(alias)
  if T.REEXPORTED_TYPES.has_key?(name)
    wrapper = STD_ONLY[alias]
    help = (
      "#{alias} is internal to #{wrapper[0]}; write #{T.REEXPORTED_TYPES[name]}, with import #{wrapper[1]} from " +
      "\"#{wrapper[0]}\""
    )
  end

  Failure.fail_at(site(cx, span), "CHECK-UNKNOWN-NAME", "unknown #{wanted_word(want)} \"#{name}\"", Failure.hint(help))
end

# What a position wants, as a message says it: "type", "enum" or "function".
def wanted_word(want: Want) -> String
  case want
    Want.Type -> "type"
    Want.Enum -> "enum"
    Want.Function -> "function"
  end
end

def alias_help(alias: String, member: String, hint: Bool) -> String
  if alias == "JSON" and member == "Codec"
    return "the codec type is Codec[T], and the codec of a type is T.codec"
  elsif alias == "BDD"
    return "import BDD from \"std/bdd\""
  elsif alias == "HTTP"
    return "import HTTP from \"std/http\""
  elsif alias == "Result"
    return "write Result.Ok(value) or ok(value), Result.Err(\"message\") or error(\"message\")"
  elsif alias == "Optional"
    return "an Optional is written some(value) or none"
  elsif alias == "Math"
    return "Math has only Math.sqrt; write pi as 3.141592653589793 and e as 2.718281828459045"
  elsif Builtins.moved_type(alias) != ""
    return Builtins.moved_type(alias)
  elsif RESERVED.include?(alias)
    return "#{alias} is a builtin name, so it is no import alias, and it has no such constant or type"
  elsif hint
    return (
      "\"#{alias}\" is neither an import alias nor an enum of this file; " +
      "import a module with import #{alias} from \"path\", or declare enum #{alias}"
    )
  end

  "import a module with import #{alias} from \"path\""
end

# A name bound by import {Name} from "path": the linked name of the export, if it is of the kind wanted. The import
# already checked that the module exports it.
def imported_by_name(cx: Context, entry: Modules.Named, want: Want, span: Source.Span) -> Result[String]
  target = cx.modules[entry.target]
  if !right_kind?(Modules.kind_in(target, entry.name), want)
    return error(
      Failure.fail_at(site(cx, span), "CHECK-TYPE-MISMATCH", "wrong kind of imported declaration", Diag.Help.NoHelp),
    )
  end

  ok(Modules.linked_name(cx.modules, target, entry.name))
end

# Only exports are candidates, so a private name is never suggested.
def imported(cx: Context, target: Modules.Module, member: String, want: Want, span: Source.Span) -> Result[String]
  if !target.public.has_key?(member)
    return error(
      Failure.fail_at(
        site(cx, span),
        "CHECK-IMPORT-NAME",
        "unknown or private imported name",
        ImportHelp.unknown_import_help(target.key, target.public, member),
      ),
    )
  end

  if !right_kind?(target.public[member], want)
    return error(
      Failure.fail_at(site(cx, span), "CHECK-TYPE-MISMATCH", "wrong kind of imported declaration", Diag.Help.NoHelp),
    )
  end

  ok(Modules.linked_name(cx.modules, target, member))
end

def right_kind?(kind: Declarations.Kind, want: Want) -> Bool
  case want
    Want.Type ->
      (
        Declarations.struct?(kind) or
        Declarations.enum?(kind) or
        Declarations.type_alias?(kind) or
        Declarations.resource?(kind)
      )
    Want.Enum -> Declarations.enum?(kind)
    Want.Function -> Declarations.function?(kind)
  end
end
