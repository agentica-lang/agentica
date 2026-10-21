## The query commands (docs/future/39-semantic-cli.md): `agentica outline FILE [--json] [--stdin FILE]`,
## `agentica type-at FILE:LINE:COL [--json]` (`type-at --stdin FILE:LINE:COL` reads FILE from standard input) and
## `agentica symbol NAME [PATH...] [--json] [--stdin FILE]`. A query reads its file through the Workspace of the
## settings, which is the standard input for `--stdin` (cli.agc, `with_buffer`), and answers in text or in JSON.
## `outline` never links or checks, so the imports of the file need not exist; `type-at` links and checks the file and
## what it imports, without requiring `main`; `symbol` links each file of its paths on its own and lists the ones that
## do not link.
##
## A mistake in the question is a QUERY- diagnostic and exit status 2; a diagnostic of the file (lexer, parser, linker
## or checker) is exit status 1 (cli.agc prints both).

import Diag from "../diagnostics/diagnostic"
import Env from "../modules/link_env"
import Outline from "../query/outline"
import OutlineJson from "../query/outline_json"
import OutlineText from "../query/outline_text"
import QueryFiles from "../query/query_files"
import QueryOptions from "../query/query_options"
import QueryPosition from "../query/query_position"
import Symbol from "../query/symbol"
import SymbolJson from "../query/symbol_json"
import SymbolPaths from "../query/symbol_paths"
import SymbolText from "../query/symbol_text"
import TypeAt from "../query/type_at"
import TypeAtJson from "../query/type_at_json"
import TypeAtText from "../query/type_at_text"
import Ast from "../syntax/ast"
import SourceFile from "../syntax/source_file"
import Pipeline from "pipeline"
import Reply from "cli_reply"

# The usage line of each query command, given as the help of QUERY-USAGE.
OUTLINE_USAGE = "usage: agentica outline FILE [--json]   or   agentica outline --stdin FILE [--json]"
TYPE_AT_USAGE = "usage: agentica type-at FILE:LINE:COL [--json]   or   agentica type-at --stdin FILE:LINE:COL [--json]"
SYMBOL_USAGE = "usage: agentica symbol NAME [PATH...] [--json] [--stdin FILE]"

## The usage line of `agentica outline`.
export def outline_usage() -> String
  return OUTLINE_USAGE
end

## The usage line of `agentica type-at`.
export def type_at_usage() -> String
  return TYPE_AT_USAGE
end

## The usage line of `agentica symbol`.
export def symbol_usage() -> String
  return SYMBOL_USAGE
end

## `agentica outline` for `file`. `buffered` is true when the Workspace of `settings` holds the standard input as
## `file`; `style` is "json" for the JSON form.
export def outline(file: String, style: String, buffered: Bool, settings: Env.Settings) -> Reply.Answer
  case QueryFiles.read(settings, file, buffered)
    SourceFile.Read.Unreadable(_) -> return Reply.Answer.Rejected(QueryFiles.unreadable(file, OUTLINE_USAGE))
    SourceFile.Read.Invalid(at) ->
      return Reply.Answer.Rejected(Pipeline.stage_problem(file, SourceFile.invalid_utf8(at)))
    SourceFile.Read.Text(text) ->
      name = QueryFiles.display(settings, file, buffered)
      return outlined(file, name, text, style == "json")
  end
end

## `agentica type-at` for the position `asked`. The Workspace of `settings` answers the file of the position, from the
## disk or from the standard input; either way it is a path, never a `std/` module. The file is linked and checked with
## the rule that a program declares `main` off; a diagnostic of that is exit status 1, and a position that is on no
## expression is QUERY-NO-EXPRESSION.
export def type_at(asked: QueryPosition.Asked, style: String, settings: Env.Settings) -> Reply.Answer
  case Pipeline.read_root(settings.workspace, asked.file)
    Pipeline.Root.Unreadable(_) -> return Reply.Answer.Rejected(QueryFiles.unreadable(asked.file, TYPE_AT_USAGE))
    Pipeline.Root.Invalid(problem) -> return Reply.Answer.Rejected(problem)
    Pipeline.Root.Readable ->
      case Pipeline.query_file(asked.file, settings)
        Pipeline.Front.Rejected(problem) -> return Reply.Answer.Rejected(problem)
        Pipeline.Front.Done(front) -> return located(asked, style == "json", front, settings)
      end
  end
end

## `agentica symbol` for the words after the command: NAME, then the files and folders to search (`.` by default).
## `asked.stdin` is the FILE whose text the Workspace of `settings` holds as the standard input, if any; it is searched
## too. The answer is in the JSON form for `asked.style` "json"; in the text form the roots that were left out are one
## line each on stderr. A name nothing declares is QUERY-NOT-FOUND, and when no root links the first problem of the
## first one is the answer.
export def symbol(asked: QueryOptions.Query, settings: Env.Settings) -> Reply.Answer
  if asked.words.size == 0 or asked.words[0] == ""
    return Reply.Answer.Rejected(QueryOptions.refusal("missing NAME", SYMBOL_USAGE))
  end
  name = asked.words[0]
  case SymbolPaths.expand(settings.workspace, asked.words.drop(1), asked.stdin, SYMBOL_USAGE)
    SymbolPaths.Expanded.Refused(problem) -> return Reply.Answer.Rejected(problem)
    SymbolPaths.Expanded.Files(roots) ->
      case Symbol.answer(name, roots, settings)
        Symbol.Outcome.Refused(problem) -> return Reply.Answer.Rejected(problem)
        Symbol.Outcome.Found(found) -> return symbols(name, found, asked.style == "json", settings)
      end
  end
end

def symbols(name: String, found: Symbol.Answer, as_json: Bool, settings: Env.Settings) -> Reply.Answer
  named = found.with(matches: found.matches.map do |match: Symbol.Match| shown(match, settings) end)
  if as_json
    return Reply.Answer.Printed(Reply.printed("#{JSON.encode(SymbolJson.json(name, named))}\n"))
  end
  return Reply.Answer.Printed(
    Reply.Reply(code: 0, out: SymbolText.text(named.matches), err: SymbolText.skipped_text(named.skipped)),
  )
end

# The match with the name its answer gives its file; a builtin has none.
def shown(match: Symbol.Match, settings: Env.Settings) -> Symbol.Match
  if match.file == ""
    return match
  end
  return match.with(file: QueryFiles.display(settings, match.file, true))
end

def located(
  asked: QueryPosition.Asked,
  as_json: Bool,
  front: Pipeline.Checked,
  settings: Env.Settings,
) -> Reply.Answer
  case TypeAt.answer(front.linked, front.checked, asked)
    Diag.Outcome.Failed(problem) -> return Reply.Answer.Rejected(Pipeline.stage_problem(asked.file, problem))
    Diag.Outcome.Done(found) ->
      name = QueryFiles.display(settings, asked.file, true)
      home = QueryFiles.display(settings, definition_file(found), true)
      if as_json
        return Reply.Answer.Printed(Reply.printed("#{JSON.encode(TypeAtJson.json(name, asked, found, home))}\n"))
      end
      return Reply.Answer.Printed(Reply.printed(TypeAtText.text(name, found, home)))
  end
end

# The file of the definition; "" when the answer has none.
def definition_file(found: TypeAt.Answer) -> String
  case found.definition
    Ast.Optional.Present(definition) -> return definition.file
    Ast.Optional.Absent -> return ""
  end
end

def outlined(file: String, name: String, text: String, as_json: Bool) -> Reply.Answer
  case Outline.of_text(text)
    Diag.Outcome.Failed(problem) -> return Reply.Answer.Rejected(Pipeline.stage_problem(file, problem))
    Diag.Outcome.Done(found) ->
      if as_json
        return Reply.Answer.Printed(Reply.printed("#{JSON.encode(OutlineJson.json(name, found))}\n"))
      end
      return Reply.Answer.Printed(Reply.printed(OutlineText.text(name, found)))
  end
end
