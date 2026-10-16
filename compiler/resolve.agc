## Name resolution of the linker: what a name written in one file is called in the linked program.
##
## A name declared in the root file keeps its name; a name declared in another file gets the prefix of that file
## ("@2::"), so equal names of two files stay apart. A name through an import alias (Alias.name) becomes the prefixed
## name in the imported file, if that file exports it.

import Ast from "ast"
import Declarations from "declarations"
import Diag from "diagnostic"
import Env from "link_env"
import Failure from "link_failure"
import Modules from "modules"
import Base from "parse_base"
import Resolve from "resolve_import"
import Source from "source"
import Suggest from "suggest"
import {BARE_NAMES, ENUMS, RESERVED, STD_ONLY} from "builtins"

## What the linker knows while it rewrites one file: the settings, every module, the file itself, the linked names of
## the user structs the file may update (StructUpdate.visible), and ids, the number of node ids of the program (the
## receiver of a rewritten NAME.method(...) takes the id ids + the id of the call).
export struct Context
  settings: Env.Settings
  modules: Map[String, Modules.Module]
  me: Modules.Module
  visible: List[String]
  ids: Int
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
      return target.prefix + entry.name
    end
  end
  return ""
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
    return imported(cx, alias, cx.modules[target], member, want, span)
  elsif STD_ONLY.has_key?(alias) and !Resolve.embedded?(cx.me.key)
    return error(std_only_failure(cx, alias, member, span))
  elsif function_wanted?(want)
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
  return ok(target.prefix + entry.name)
end

# Mod.NAME on a constant: the import that reads it, with the path as the alias import wrote it, and the other way.
def constant_help(cx: Context, alias: String, member: String) -> String
  path = cx.me.paths[alias]
  return (
    "write import {#{member}} from \"#{path}\", then use #{member}\n" +
    "or let the module export a function and call it as #{alias}.name()"
  )
end

# Only exports are candidates, so a private name is never suggested.
def imported(
  cx: Context,
  alias: String,
  target: Modules.Module,
  member: String,
  want: Want,
  span: Source.Span,
) -> Result[String]
  if !target.public.has_key?(member)
    return error(
      Failure.fail_at(
        site(cx, span),
        "CHECK-IMPORT-NAME",
        "unknown or private imported name",
        Suggest.unknown_import_help(target.key, target.public, member, true),
      ),
    )
  end
  if Declarations.constant?(target.public[member])
    return error(
      Failure.fail_at(
        site(cx, span),
        "CHECK-IMPORT-NAME",
        "a constant is read by its name, not through the module alias",
        Failure.hint(constant_help(cx, alias, member)),
      ),
    )
  end
  if !right_kind?(target.public[member], want)
    return error(
      Failure.fail_at(site(cx, span), "CHECK-TYPE-MISMATCH", "wrong kind of imported declaration", Diag.Help.NoHelp),
    )
  end
  return ok(target.prefix + member)
end

def right_kind?(kind: Declarations.Kind, want: Want) -> Bool
  case want
    Want.Type -> return Declarations.struct?(kind) or Declarations.enum?(kind) or Declarations.type_alias?(kind)
    Want.Enum -> return Declarations.enum?(kind)
    Want.Function -> return Declarations.function?(kind)
  end
end
