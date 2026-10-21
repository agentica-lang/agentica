## The query commands (docs/future/39-semantic-cli.md): `agentica outline FILE [--json] [--stdin FILE]` and `agentica
## type-at FILE:LINE:COL [--json]` (`type-at --stdin FILE:LINE:COL` reads FILE from standard input). A query reads its
## file through the Workspace of the settings, which is the standard input for `--stdin` (cli.agc, `with_buffer`), and
## answers in text or in JSON. `outline` never links or checks, so the imports of the file need not exist; `type-at`
## links and checks the file and what it imports, without requiring `main`.
##
## A mistake in the question is a QUERY- diagnostic and exit status 2; a diagnostic of the file (lexer, parser, linker
## or checker) is exit status 1 (cli.agc prints both).

import Ast from "../syntax/ast"
import Diag from "../diagnostics/diagnostic"
import Env from "../modules/link_env"
import Outline from "../query/outline"
import OutlineJson from "../query/outline_json"
import OutlineText from "../query/outline_text"
import Pipeline from "pipeline"
import QueryFiles from "../query/query_files"
import QueryPosition from "../query/query_position"
import Reply from "cli_reply"
import SourceFile from "../syntax/source_file"
import TypeAt from "../query/type_at"
import TypeAtJson from "../query/type_at_json"
import TypeAtText from "../query/type_at_text"

# The usage line of each query command, given as the help of QUERY-USAGE.
OUTLINE_USAGE = "usage: agentica outline FILE [--json]   or   agentica outline --stdin FILE [--json]"
TYPE_AT_USAGE = "usage: agentica type-at FILE:LINE:COL [--json]   or   agentica type-at --stdin FILE:LINE:COL [--json]"

## The usage line of `agentica outline`.
export def outline_usage() -> String
  return OUTLINE_USAGE
end

## The usage line of `agentica type-at`.
export def type_at_usage() -> String
  return TYPE_AT_USAGE
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
