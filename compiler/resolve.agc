## Name resolution of the linker: what a name written in one file is called in the linked program. This is resolve of src/modules.rkt.
##
## A name declared in the root file keeps its name; a name declared in another file gets the prefix of that file ("@2::"), so equal names of two files stay apart. A name through an import alias (Alias.name) becomes the prefixed name in the imported file, if that file exports it.

import Declarations from "declarations"
import Diag from "diagnostic"
import Env from "link_env"
import Failure from "link_failure"
import Modules from "modules"
import Resolve from "resolve_import"
import Source from "source"
import Suggest from "suggest"

## What the linker knows while it rewrites one file: the settings, every module, the file itself, and the linked names of the user structs the file may update (StructUpdate.visible).
export struct Context
  settings: Env.Settings
  modules: Map[String, Modules.Module]
  me: Modules.Module
  visible: List[String]
end

## What a name must be where it is written: a type (a struct or enum), an enum, or a function.
export enum Want
  Type
  Enum
  Function
end

## The name in the linked program for a name written in the file. want says what the name must be. hint adds the enum hint to the help of an unknown alias. A failure is CHECK-IMPORT-NAME, CHECK-TYPE-MISMATCH or CHECK-UNKNOWN-NAME at span.
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

## The name in the linked program of a declaration of the file.
export def identity(cx: Context, name: String) -> String
  return cx.me.prefix + name
end

# A reserved type, a builtin enum (and Result), or a bare builtin function keeps its name.
def builtin_name?(cx: Context, name: String, want: Want) -> Bool
  case want
    Want.Type -> return cx.settings.catalog.reserved.include?(name)
    Want.Enum -> return name == "Result" or cx.settings.catalog.enums.has_key?(name)
    Want.Function -> return cx.settings.catalog.bare_names.include?(name)
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
  elsif cx.settings.catalog.std_only.has_key?(alias) and !Resolve.embedded?(cx.me.key)
    return error(std_only_failure(cx, alias, member, span))
  elsif function_wanted?(want)
    return ok(alias + "." + member)
  end
  return error(Failure.fail_at(site(cx, span), "CHECK-IMPORT-NAME", "unknown module alias", Failure.hint(alias_help(alias, hint))))
end

def function_wanted?(want: Want) -> Bool
  case want
    Want.Function -> return true
    _ -> return false
  end
end

def std_only_failure(cx: Context, alias: String, member: String, span: Source.Span) -> String
  wrapper = cx.settings.catalog.std_only[alias]
  help = alias + " is internal to " + wrapper.std_path + "; use import " + wrapper.alias + " from \"" + wrapper.std_path + "\""
  return Failure.fail_at(site(cx, span), "CHECK-UNKNOWN-NAME", "unknown function \"" + alias + "." + member + "\"", Failure.hint(help))
end

def alias_help(alias: String, hint: Bool) -> String
  if alias == "BDD"
    return "import BDD from \"std/bdd\""
  elsif alias == "HTTP"
    return "import HTTP from \"std/http\""
  elsif alias == "Result"
    return "write Result.Ok(value) or ok(value), Result.Err(\"message\") or error(\"message\")"
  elsif hint
    return "\"" + alias + "\" is neither an import alias nor an enum of this file; import a module with import " + alias + " from \"path\", or declare enum " + alias
  end
  return "import a module with import " + alias + " from \"path\""
end

# A name bound by import {Name} from "path": the linked name of the export, if it is of the kind wanted. The import already checked that the module exports it.
def imported_by_name(cx: Context, entry: Modules.Named, want: Want, span: Source.Span) -> Result[String]
  target = cx.modules[entry.target]
  if !right_kind?(target.public[entry.name], want)
    return error(Failure.fail_at(site(cx, span), "CHECK-TYPE-MISMATCH", "wrong kind of imported declaration", Diag.Help.NoHelp))
  end
  return ok(target.prefix + entry.name)
end

# Only exports are candidates, so a private name is never suggested.
def imported(cx: Context, target: Modules.Module, member: String, want: Want, span: Source.Span) -> Result[String]
  if !target.public.has_key?(member)
    return error(Failure.fail_at(site(cx, span), "CHECK-IMPORT-NAME", "unknown or private imported name", Suggest.unknown_import_help(target.key, target.public.keys, member)))
  end
  if !right_kind?(target.public[member], want)
    return error(Failure.fail_at(site(cx, span), "CHECK-TYPE-MISMATCH", "wrong kind of imported declaration", Diag.Help.NoHelp))
  end
  return ok(target.prefix + member)
end

def right_kind?(kind: Declarations.Kind, want: Want) -> Bool
  case want
    Want.Type -> return Declarations.struct?(kind) or Declarations.enum?(kind)
    Want.Enum -> return Declarations.enum?(kind)
    Want.Function -> return Declarations.function?(kind)
  end
end
