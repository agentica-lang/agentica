## The query commands (docs/future/39-semantic-cli.md): `agentica outline FILE [--json] [--stdin FILE]`, `agentica
## type-at FILE:LINE:COL [--json]` and `agentica refs FILE:LINE:COL [--json]` (`type-at --stdin FILE:LINE:COL` reads
## FILE from standard input). A query reads its file through the Workspace of the settings, which is the standard
## input for `--stdin` (cli.agc, `with_buffer`), and answers in text or in JSON. `outline` never links or checks, so
## the imports of the file need not exist; `type-at` and `refs` link and check the file and what it imports, without
## requiring `main`.
##
## A mistake in the question is a QUERY- diagnostic and exit status 2; a diagnostic of the file (lexer, parser, linker
## or checker) is exit status 1 (cli.agc prints both).

import Ast from "../syntax/ast"
import Diag from "../diagnostics/diagnostic"
import Definitions from "../query/definitions"
import Env from "../modules/link_env"
import Outline from "../query/outline"
import OutlineJson from "../query/outline_json"
import OutlineText from "../query/outline_text"
import Pipeline from "pipeline"
import QueryFiles from "../query/query_files"
import QueryPosition from "../query/query_position"
import Refs from "../query/refs"
import RefsJson from "../query/refs_json"
import RefsText from "../query/refs_text"
import Reply from "cli_reply"
import SourceFile from "../syntax/source_file"
import TypeAt from "../query/type_at"
import TypeAtJson from "../query/type_at_json"
import TypeAtText from "../query/type_at_text"

# The usage line of each query command, given as the help of QUERY-USAGE.
OUTLINE_USAGE = "usage: agentica outline FILE [--json]   or   agentica outline --stdin FILE [--json]"
TYPE_AT_USAGE = "usage: agentica type-at FILE:LINE:COL [--json]   or   agentica type-at --stdin FILE:LINE:COL [--json]"
REFS_USAGE = "usage: agentica refs FILE:LINE:COL [--json]   or   agentica refs --stdin FILE:LINE:COL [--json]"

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
  return with_front(asked, TYPE_AT_USAGE, settings) do |front: Pipeline.Checked|
    located(asked, style == "json", front, settings)
  end
end

## `agentica refs` for the position `asked`, linked and checked as `type_at` does. It lists the references to the name
## at the position in the file and what it imports, or is QUERY-NO-EXPRESSION when the position names nothing.
export def refs(asked: QueryPosition.Asked, style: String, settings: Env.Settings) -> Reply.Answer
  return with_front(asked, REFS_USAGE, settings) do |front: Pipeline.Checked|
    referenced(asked, style == "json", front, settings)
  end
end

# Links and checks the file of the position, and gives `then` the result.
def with_front(
  asked: QueryPosition.Asked,
  usage: String,
  settings: Env.Settings,
  then: Fn[Pipeline.Checked, Reply.Answer],
) -> Reply.Answer
  case Pipeline.read_root(settings.workspace, asked.file)
    Pipeline.Root.Unreadable(_) -> return Reply.Answer.Rejected(QueryFiles.unreadable(asked.file, usage))
    Pipeline.Root.Invalid(problem) -> return Reply.Answer.Rejected(problem)
    Pipeline.Root.Readable ->
      case Pipeline.query_file(asked.file, settings)
        Pipeline.Front.Rejected(problem) -> return Reply.Answer.Rejected(problem)
        Pipeline.Front.Done(front) -> return then.call(front)
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

def referenced(
  asked: QueryPosition.Asked,
  as_json: Bool,
  front: Pipeline.Checked,
  settings: Env.Settings,
) -> Reply.Answer
  case Refs.answer(front.linked, front.checked, asked)
    Diag.Outcome.Failed(problem) -> return Reply.Answer.Rejected(Pipeline.stage_problem(asked.file, problem))
    Diag.Outcome.Done(found) ->
      names = file_names(settings, found)
      if as_json
        return Reply.Answer.Printed(Reply.printed("#{JSON.encode(RefsJson.json(names, asked, found))}\n"))
      end
      return Reply.Answer.Printed(Reply.printed(RefsText.text(names, found)))
  end
end

# The name that the answer gives each file it mentions.
def file_names(settings: Env.Settings, found: Refs.Answer) -> Map[String, String]
  files: List[String] = found.references.map do |reference: Refs.Reference| reference.file end
  files = files.push(definition_file_of(found.definition))
  names: Map[String, String] = {}
  for file in files
    if file != "" and !names.has_key?(file)
      names = names.put(file, QueryFiles.display(settings, file, true))
    end
  end
  return names
end

# The file of the definition; "" when the answer has none.
def definition_file(found: TypeAt.Answer) -> String
  return definition_file_of(found.definition)
end

def definition_file_of(definition: Ast.Optional[Definitions.Definition]) -> String
  case definition
    Ast.Optional.Present(found) -> return found.file
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
