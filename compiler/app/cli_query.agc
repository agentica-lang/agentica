## The query commands (docs/future/39-semantic-cli.md): `agentica outline FILE [--json] [--partial] [--stdin FILE]`,
## `agentica type-at FILE:LINE:COL [--json] [--partial]` and `agentica refs FILE:LINE:COL [--json] [--partial]`
## (both read FILE from standard input with `--stdin FILE:LINE:COL`) and `agentica symbol NAME [PATH...] [--json]
## [--stdin FILE]`. A query reads its file through the Workspace of the settings, which is the standard input for
## `--stdin` (cli.agc, `with_buffer`), and answers in text or in JSON. `outline` never links or checks, so the
## imports of the file need not exist; `type-at` and `refs` link and check the file and what it imports, without
## requiring `main`; `symbol` links each file of its paths on its own and lists the ones that do not link.
##
## With `--partial`, `type-at` and `refs` also answer from a program in which some functions do not check (39.6):
## the answer has `partial` and `diagnostics` in the JSON form, one line on stderr for each diagnostic in the text
## form, and the exit status is 0. A program that checks gets the answer it gets without the option. `outline` takes
## the option and has nothing to add: it never checks.
##
## A mistake in the question is a QUERY- diagnostic and exit status 2; a diagnostic of the file (lexer, parser, linker
## or checker) is exit status 1 (cli.agc prints both).

import Core from "../analysis/analysis"
import DiagnosticModel from "../diagnostics/diagnostic_model"
import Env from "../modules/link_env"
import OutlineJson from "../query/outline_json"
import OutlineText from "../query/outline_text"
import QueryFiles from "../query/query_files"
import QueryOptions from "../query/query_options"
import QueryPosition from "../query/query_position"
import RefsJson from "../query/refs_json"
import RefsText from "../query/refs_text"
import Reply from "cli_reply"
import SymbolJson from "../query/symbol_json"
import SymbolText from "../query/symbol_text"
import TypeAtJson from "../query/type_at_json"
import TypeAtText from "../query/type_at_text"

# The usage line of each query command, given as the help of QUERY-USAGE.
OUTLINE_USAGE = (
  "usage: agentica outline FILE [--json] [--partial]   or   " + "agentica outline --stdin FILE [--partial]"
)
TYPE_AT_USAGE = (
  "usage: agentica type-at FILE:LINE:COL [--json] [--partial]   or   " + "agentica type-at --stdin FILE:LINE:COL [--partial]"
)
REFS_USAGE = (
  "usage: agentica refs FILE:LINE:COL [--json] [--partial]   or   " + "agentica refs --stdin FILE:LINE:COL [--partial]"
)
SYMBOL_USAGE = "usage: agentica symbol NAME [PATH...] [--json] [--stdin FILE]"

## The usage line of `agentica outline`.
export def outline_usage() -> String
  return OUTLINE_USAGE
end

## The usage line of `agentica type-at`.
export def type_at_usage() -> String
  return TYPE_AT_USAGE
end

## The usage line of `agentica refs`.
export def refs_usage() -> String
  return REFS_USAGE
end

## The usage line of `agentica symbol`.
export def symbol_usage() -> String
  return SYMBOL_USAGE
end

## `agentica outline` for `file`. `buffered` is true when the Workspace of `settings` holds the standard input as
## `file`; `style` is "json" for the JSON form.
export def outline(file: String, style: String, buffered: Bool, settings: Env.Settings) -> Reply.Answer
  case Core.outline(settings, file, buffered)
    Core.Outlined.Unreadable -> return Reply.Answer.Rejected(QueryFiles.unreadable(file, OUTLINE_USAGE))
    Core.Outlined.Rejected(problem) -> return Reply.Answer.Rejected(problem)
    Core.Outlined.Done(found) ->
      if style == "json"
        return Reply.Answer.Printed(Reply.printed("#{JSON.encode(OutlineJson.json(found))}\n"))
      end
      return Reply.Answer.Printed(Reply.printed(OutlineText.text(found)))
  end
end

## `agentica type-at` for the position `asked`. The Workspace of `settings` answers the file of the position, from the
## disk or from the standard input; either way it is a path, never a `std/` module. The file is linked and checked with
## the rule that a program declares `main` off; a diagnostic of that is exit status 1, and a position that is on no
## expression is QUERY-NO-EXPRESSION. With `partial`, a program in which some functions do not check is answered too
## (`Core.type_at_partial`).
export def type_at(asked: QueryPosition.Asked, style: String, partial: Bool, settings: Env.Settings) -> Reply.Answer
  asking = Core.type_at(settings, asked)
  if partial
    asking = Core.type_at_partial(settings, asked)
  end
  case asking
    Core.Typed.Unreadable -> return Reply.Answer.Rejected(QueryFiles.unreadable(asked.file, TYPE_AT_USAGE))
    Core.Typed.Rejected(problem) -> return Reply.Answer.Rejected(problem)
    Core.Typed.Done(found) ->
      if style == "json"
        return Reply.Answer.Printed(Reply.printed("#{JSON.encode(TypeAtJson.json(found))}\n"))
      end
      text = TypeAtText.text(found)
      return Reply.Answer.Printed(Reply.Reply(code: 0, out: text, err: partial_text(found.diagnostics)))
  end
end

## `agentica refs` for the position `asked`, linked and checked as `type_at` does. It lists the references to the name
## at the position in the file and what it imports, or is QUERY-NO-EXPRESSION when the position names nothing. With
## `partial`, a program in which some functions do not check is answered too (`Core.refs_partial`).
export def refs(asked: QueryPosition.Asked, style: String, partial: Bool, settings: Env.Settings) -> Reply.Answer
  asking = Core.refs(settings, asked)
  if partial
    asking = Core.refs_partial(settings, asked)
  end
  case asking
    Core.Referenced.Unreadable -> return Reply.Answer.Rejected(QueryFiles.unreadable(asked.file, REFS_USAGE))
    Core.Referenced.Rejected(problem) -> return Reply.Answer.Rejected(problem)
    Core.Referenced.Done(found) ->
      if style == "json"
        return Reply.Answer.Printed(Reply.printed("#{JSON.encode(RefsJson.json(found))}\n"))
      end
      text = RefsText.text(found)
      return Reply.Answer.Printed(Reply.Reply(code: 0, out: text, err: partial_text(found.diagnostics)))
  end
end

## `agentica symbol` for the words after the command: NAME, then the files and folders to search (`.` by default).
## `asked.stdin` is the FILE whose text the Workspace of `settings` holds as the standard input, if any; it is searched
## too. The answer is in the JSON form for `asked.style` "json"; in the text form the roots that were left out are one
## line each on stderr. A name nothing declares is QUERY-NOT-FOUND, and when no root links the first problem of the
## first one is the answer.
export def symbol(asked: QueryOptions.Query, settings: Env.Settings) -> Reply.Answer
  name = ""
  if asked.words.size > 0
    name = asked.words[0]
  end
  case Core.symbol(settings, name, asked.words.drop(1), asked.stdin, SYMBOL_USAGE)
    Core.Found.Rejected(problem) -> return Reply.Answer.Rejected(problem)
    Core.Found.Done(found) ->
      if asked.style == "json"
        return Reply.Answer.Printed(Reply.printed("#{JSON.encode(SymbolJson.json(found))}\n"))
      end
      return Reply.Answer.Printed(
        Reply.Reply(code: 0, out: SymbolText.text(found), err: SymbolText.skipped_text(found)),
      )
  end
end

# The text form of the problems of a partial answer, one line each on stderr: `partial FILE:LINE:COL: CODE`. A complete
# answer has none.
def partial_text(diagnostics: List[DiagnosticModel.Diagnostic]) -> String
  lines = diagnostics.map do |found: DiagnosticModel.Diagnostic|
    "partial #{OutlineText.place(found.file, found.range)}: #{found.code}\n"
  end
  return lines.join("")
end
