## Name resolution of the linker: what a name written in one file is called in the linked program. This is resolve of src/modules.rkt.
##
## A name declared in the root file keeps its name; a name declared in another file gets the prefix of that file ("@2::"), so equal names of two files stay apart. A name through an import alias (Alias.name) becomes the prefixed name in the imported file, if that file exports it.

import "ast" as Ast
import "diagnostic" as Diag
import "link_env" as Env
import "link_failure" as Failure
import "modules" as Modules
import "resolve_import" as Resolve
import "source" as Source
import "suggest" as Suggest

## What the linker knows while it rewrites one file: the settings, every module, and the file itself.
export struct Context
  settings: Env.Settings
  modules: Map[String, Modules.Module]
  me: Modules.Module
end

## The name in the linked program for a name written in the file. want says what the name must be: "type" (a struct or enum), "enum" or "function". hint adds the enum hint to the help of an unknown alias. A failure is CHECK-IMPORT-NAME, CHECK-TYPE-MISMATCH or CHECK-UNKNOWN-NAME at span.
export def resolve(cx: Context, name: String, want: String, span: Source.Span, hint: Bool) -> Result[String]
  parts = name.split(".")
  if parts.size == 2
    return qualified(cx, parts[0], parts[1], want, span, hint)
  end
  if want == "type" and cx.settings.reserved.include?(name)
    return ok(name)
  end
  if want == "enum" and (name == "Result" or cx.settings.builtin_enums.include?(name))
    return ok(name)
  end
  if want == "function" and cx.settings.bare_builtins.include?(name)
    return ok(name)
  end
  return ok(cx.me.prefix + name)
end

## The name in the linked program of a declaration of the file.
export def identity(cx: Context, name: String) -> String
  return cx.me.prefix + name
end

def site(cx: Context, span: Source.Span) -> Failure.Site
  return Failure.Site(file: cx.me.file, span: span)
end

# Alias.member: through an import, or a builtin module call that the checker will judge.
def qualified(cx: Context, alias: String, member: String, want: String, span: Source.Span, hint: Bool) -> Result[String]
  target = cx.me.aliases.get(alias, "")
  if target != ""
    return imported(cx, cx.modules[target], member, want, span)
  elsif cx.settings.std_only.has_key?(alias) and !Resolve.embedded?(cx.me.key)
    return error(std_only_failure(cx, alias, member, span))
  elsif want == "function"
    return ok(alias + "." + member)
  end
  return error(Failure.fail_at(site(cx, span), "CHECK-IMPORT-NAME", "unknown module alias", Failure.hint(alias_help(alias, hint))))
end

def std_only_failure(cx: Context, alias: String, member: String, span: Source.Span) -> String
  wrapper = cx.settings.std_only[alias]
  help = alias + " is internal to " + wrapper[0] + "; use import \"" + wrapper[0] + "\" as " + wrapper[1]
  return Failure.fail_at(site(cx, span), "CHECK-UNKNOWN-NAME", "unknown function \"" + alias + "." + member + "\"", Failure.hint(help))
end

def alias_help(alias: String, hint: Bool) -> String
  if alias == "BDD"
    return "import \"std/bdd\" as BDD"
  elsif alias == "HTTP"
    return "import \"std/http\" as HTTP"
  elsif alias == "Result"
    return "write Result.Ok(value) or ok(value), Result.Err(\"message\") or error(\"message\")"
  elsif hint
    return "\"" + alias + "\" is neither an import alias nor an enum of this file; import a module with import \"path\" as " + alias + ", or declare enum " + alias
  end
  return "import a module with import \"path\" as " + alias
end

# Only exports are candidates, so a private name is never suggested.
def imported(cx: Context, target: Modules.Module, member: String, want: String, span: Source.Span) -> Result[String]
  kind = target.public.get(member, "")
  if kind == ""
    return error(Failure.fail_at(site(cx, span), "CHECK-IMPORT-NAME", "unknown or private imported name", unknown_help(target, member)))
  end
  if !right_kind?(kind, want)
    return error(Failure.fail_at(site(cx, span), "CHECK-TYPE-MISMATCH", "wrong kind of imported declaration", Diag.Help.NoHelp))
  end
  return ok(target.prefix + member)
end

def right_kind?(kind: String, want: String) -> Bool
  if want == "type"
    return kind == "struct" or kind == "enum"
  elsif want == "enum"
    return kind == "enum"
  end
  return kind == "function"
end

def unknown_help(target: Modules.Module, member: String) -> Diag.Help
  removed = ["respond", "begin", "write", "write_bytes", "finish"].any? do |name| name == member end
  if target.key == "std/http.agc" and removed
    return Failure.hint("a handler returns its whole response: return ok(HttpResponse(status: 200, headers: [], body: text))")
  elsif target.key == "std/logger.agc" and member == "error"
    return Failure.hint("the function for the error level is Logger.err; error is a reserved name")
  end
  case Suggest.did_you_mean(member, target.public.keys)
    Ast.Optional.Present(text) -> return Failure.hint(text)
    Ast.Optional.Absent -> return Diag.Help.NoHelp
  end
end
