## Name resolution of the linker: what a name written in one file is called in the linked program.
##
## A name declared in the root file keeps its name; a name declared in another file gets the prefix of that file
## ("@2::"), so equal names of two files stay apart. A name through an import alias (Alias.name) becomes the prefixed
## name in the imported file, if that file exports it; a name that file re-exports is the name in the file that
## declares it.

import {BARE_NAMES, ENUMS, RECORDS, RESERVED, STD_ONLY} from "../catalog/builtins"
import Diag from "../diagnostics/diagnostic"
import Ast from "../syntax/ast"
import Base from "../syntax/parse_base"
import Source from "../syntax/source"
import Suggest from "../syntax/suggest"
import Declarations from "declarations"
import ImportHelp from "import_help"
import Env from "link_env"
import Failure from "link_failure"
import Modules from "modules"
import Resolve from "resolve_import"

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
  end

  if cx.me.named.has_key?(name)
    return imported_by_name(cx, cx.me.named[name], want, span)
  end

  if builtin_name?(cx, name, want)
    return ok(name)
  end

  return ok(cx.me.prefix + name)
end

## True when the file declares an enum with this name.
export def local_enum?(cx: Context, name: String) -> Bool
  return cx.me.names.has_key?(name) and Declarations.enum?(cx.me.names[name])
end

## True when the module exports an enum with this name.
export def exports_enum?(module: Modules.Module, name: String) -> Bool
  return module.public.has_key?(name) and Declarations.enum?(module.public[name])
end

## True when the file imports an enum by name under this name.
export def named_enum?(cx: Context, name: String) -> Bool
  return cx.me.named.has_key?(name) and exports_enum?(cx.modules[cx.me.named[name].target], cx.me.named[name].name)
end

## The linked name of the constant that a name reads in this file (declared here, or imported by name), or "" when the
## name is not a constant of the file.
export def constant_identity(cx: Context, name: String) -> String
  if cx.me.names.has_key?(name) and Declarations.constant?(cx.me.names[name])
    return identity(cx, name)
  end

  if cx.me.named.has_key?(name)
    entry = cx.me.named[name]
    target = cx.modules[entry.target]
    if Declarations.constant?(target.public[entry.name])
      return Modules.linked_name(cx.modules, target, entry.name)
    end
  end

  return ""
end

## The linked name of the constant that Alias.NAME reads, or "" when the alias is unknown or the module it names does
## not export a constant of that name (a private constant is left to `resolve`, which refuses it like a private
## function).
export def alias_constant_identity(cx: Context, name: String) -> String
  # An alias is a single segment, so only `Alias.NAME` counts.
  parts = name.split(".")
  if parts.size != 2 or !cx.me.aliases.has_key?(parts[0])
    return ""
  end

  target = cx.modules[cx.me.aliases[parts[0]]]
  if target.public.has_key?(parts[1]) and Declarations.constant?(target.public[parts[1]])
    return Modules.linked_name(cx.modules, target, parts[1])
  end

  return ""
end

## True when the name is a type that the file declares or imports by name (a struct, enum, type alias or resource), or
## a builtin record such as HttpResponse.
export def declared_type?(cx: Context, name: String) -> Bool
  if cx.me.names.has_key?(name)
    return right_kind?(cx.me.names[name], Want.Type)
  end

  if cx.me.named.has_key?(name)
    entry = cx.me.named[name]
    return right_kind?(cx.modules[entry.target].public[entry.name], Want.Type)
  end

  return RECORDS.has_key?(name)
end

## A name in capitals that no declaration, import, alias or reserved type of the file owns: a constant that does not
## exist.
export def unknown_constant?(cx: Context, name: String) -> Bool
  return (
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
    entry = cx.me.named[local]
    if Declarations.constant?(cx.modules[entry.target].public[entry.name])
      seen = seen.push(local)
    end
  end

  help = Diag.Help.NoHelp
  case Suggest.did_you_mean_among(name, [], seen)
    Ast.Optional.Present(text) -> help = Failure.hint(text)
    Ast.Optional.Absent -> help = Diag.Help.NoHelp
  end

  return Failure.fail_at(site(cx, span), "CHECK-UNKNOWN-NAME", "unknown name \"#{name}\"", help)
end

## The name in the linked program of a declaration of the file.
export def identity(cx: Context, name: String) -> String
  return cx.me.prefix + name
end

# A reserved type, a builtin enum (and Result), or a bare builtin function keeps its name.
def builtin_name?(cx: Context, name: String, want: Want) -> Bool
  case want
    Want.Type -> return RESERVED.include?(name)
    Want.Enum -> return name == "Result" or ENUMS.has_key?(name)
    Want.Function -> return BARE_NAMES.include?(name)
  end
end

def site(cx: Context, span: Source.Span) -> Failure.Site
  return Failure.Site(file: cx.me.file, span: span)
end

# Alias.member: through an import, or a builtin module call that the checker will judge.
def qualified(cx: Context, alias: String, member: String, want: Want, span: Source.Span, hint: Bool) -> Result[String]
  target = cx.me.aliases.get(alias, "")
  if target != ""
    return imported(cx, cx.modules[target], member, want, span)
  elsif STD_ONLY.has_key?(alias) and !Resolve.embedded?(cx.me.key)
    return error(std_only_failure(cx, alias, member, span))
  elsif function_wanted?(want) or std_record?(alias, member, want) or c_pointer?(alias, member, want)
    return ok("#{alias}.#{member}")
  end

  return error(
    Failure.fail_at(
      site(cx, span),
      "CHECK-IMPORT-NAME",
      "unknown module alias",
      Failure.hint(alias_help(alias, hint)),
    ),
  )
end

# A builtin record of a std-only module, such as HttpWire.Head: a type that only std/ can name, so it reserves no name
# in user programs.
def std_record?(alias: String, member: String, want: Want) -> Bool
  case want
    Want.Type -> return STD_ONLY.has_key?(alias) and RECORDS.has_key?("#{alias}.#{member}")
    _ -> return false
  end
end

# C.Pointer, the builtin type of a C pointer (the extern blocks of native code), which any file may name.
def c_pointer?(alias: String, member: String, want: Want) -> Bool
  case want
    Want.Type -> return alias == "C" and member == "Pointer"
    _ -> return false
  end
end

def function_wanted?(want: Want) -> Bool
  case want
    Want.Function -> return true
    _ -> return false
  end
end

def std_only_failure(cx: Context, alias: String, member: String, span: Source.Span) -> String
  wrapper = STD_ONLY[alias]
  help = "#{alias} is internal to #{wrapper[0]}; use import #{wrapper[1]} from \"#{wrapper[0]}\""
  return Failure.fail_at(
    site(cx, span),
    "CHECK-UNKNOWN-NAME",
    "unknown function \"#{alias}.#{member}\"",
    Failure.hint(help),
  )
end

def alias_help(alias: String, hint: Bool) -> String
  if alias == "BDD"
    return "import BDD from \"std/bdd\""
  elsif alias == "HTTP"
    return "import HTTP from \"std/http\""
  elsif alias == "Result"
    return "write Result.Ok(value) or ok(value), Result.Err(\"message\") or error(\"message\")"
  elsif hint
    return (
      "\"#{alias}\" is neither an import alias nor an enum of this file; " +
      "import a module with import #{alias} from \"path\", or declare enum #{alias}"
    )
  end

  return "import a module with import #{alias} from \"path\""
end

# A name bound by import {Name} from "path": the linked name of the export, if it is of the kind wanted. The import
# already checked that the module exports it.
def imported_by_name(cx: Context, entry: Modules.Named, want: Want, span: Source.Span) -> Result[String]
  target = cx.modules[entry.target]
  if !right_kind?(target.public[entry.name], want)
    return error(
      Failure.fail_at(site(cx, span), "CHECK-TYPE-MISMATCH", "wrong kind of imported declaration", Diag.Help.NoHelp),
    )
  end

  return ok(Modules.linked_name(cx.modules, target, entry.name))
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

  return ok(Modules.linked_name(cx.modules, target, member))
end

def right_kind?(kind: Declarations.Kind, want: Want) -> Bool
  case want
    Want.Type -> return (
      Declarations.struct?(kind) or Declarations.enum?(kind) or Declarations.type_alias?(kind) or
      Declarations.resource?(kind)
    )
    Want.Enum -> return Declarations.enum?(kind)
    Want.Function -> return Declarations.function?(kind)
  end
end
