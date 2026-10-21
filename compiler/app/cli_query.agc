## The query commands (docs/future/39-semantic-cli.md): `agentica outline FILE [--json] [--stdin FILE]`. A query reads
## one file through the Workspace of the settings, which is the standard input for `--stdin` (cli.agc, `with_buffer`),
## and answers in text or in JSON. It never links or checks, so the imports of the file need not exist.
##
## A mistake in the question is a QUERY- diagnostic and exit status 2; a lexer or parser diagnostic of the file is exit
## status 1 (cli.agc prints both).

import Diag from "../diagnostics/diagnostic"
import Env from "../modules/link_env"
import Outline from "../query/outline"
import OutlineJson from "../query/outline_json"
import OutlineText from "../query/outline_text"
import Pipeline from "pipeline"
import QueryFiles from "../query/query_files"
import Reply from "cli_reply"
import SourceFile from "../syntax/source_file"

# The usage line of each query command, given as the help of QUERY-USAGE.
OUTLINE_USAGE = "usage: agentica outline FILE [--json]   or   agentica outline --stdin FILE [--json]"

## The usage line of `agentica outline`.
export def outline_usage() -> String
  return OUTLINE_USAGE
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
