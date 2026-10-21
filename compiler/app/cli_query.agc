## The query commands (docs/future/39-semantic-cli.md): `agentica outline FILE [--json] [--stdin FILE]`, `agentica
## type-at FILE:LINE:COL [--json]` (reads FILE from standard input with `--stdin FILE:LINE:COL`), `agentica symbol NAME
## [PATH...] [--json] [--stdin FILE]` and `agentica refs NAME|FILE:LINE:COL [PATH...] [--json]`, which takes `--stdin`
## as `type-at` for a position and as `symbol` for a name. A query reads its file through the Workspace of the
## settings, which is the standard input for `--stdin` (cli.agc, `with_buffer`), and answers in text or in JSON.
## `outline` never links or checks, so the imports of the file need not exist; `type-at` links and checks the file and
## what it imports, without requiring `main`; `symbol` and `refs` link the files of their paths together and list the
## ones that do not link, and `refs` checks the program too.
##
## A mistake in the question is a QUERY- diagnostic and exit status 2; a diagnostic of the file (lexer, parser, linker
## or checker) is exit status 1 (cli.agc prints both).

import Core from "../analysis/analysis"
import Env from "../modules/link_env"
import OutlineJson from "../query/outline_json"
import OutlineText from "../query/outline_text"
import Problems from "../diagnostics/problem"
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
OUTLINE_USAGE = "usage: agentica outline FILE [--json]   or   agentica outline --stdin FILE [--json]"
TYPE_AT_USAGE = "usage: agentica type-at FILE:LINE:COL [--json]   or   agentica type-at --stdin FILE:LINE:COL [--json]"
REFS_USAGE = [
  "usage: agentica refs NAME [PATH...] [--json]   or   agentica refs FILE:LINE:COL [PATH...] [--json]   or   ",
  "agentica refs --stdin FILE:LINE:COL [PATH...] [--json]",
].join("")
SYMBOL_USAGE = "usage: agentica symbol NAME [PATH...] [--json] [--stdin FILE]"

## What the words of `agentica refs` ask: a position and the paths to link with its file, a name and the paths to
## search, or why the words are wrong.
export enum RefsAsk
  At(QueryPosition.Asked, List[String])
  Named(String, List[String])
  Refused(Problems.Problem)
end

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
## expression is QUERY-NO-EXPRESSION.
export def type_at(asked: QueryPosition.Asked, style: String, settings: Env.Settings) -> Reply.Answer
  case Core.type_at(settings, asked)
    Core.Typed.Unreadable -> return Reply.Answer.Rejected(QueryFiles.unreadable(asked.file, TYPE_AT_USAGE))
    Core.Typed.Rejected(problem) -> return Reply.Answer.Rejected(problem)
    Core.Typed.Done(found) ->
      if style == "json"
        return Reply.Answer.Printed(Reply.printed("#{JSON.encode(TypeAtJson.json(found))}\n"))
      end
      return Reply.Answer.Printed(Reply.printed(TypeAtText.text(found)))
  end
end

## Reads the words of `refs`. The first word is `FILE:LINE:COL` or a NAME, and the others are paths; `--stdin
## FILE:LINE:COL` stands in for the first word. A word with a colon is a position, which a name never has, so a bad
## position is QUERY-USAGE and not a name that nothing declares.
export def refs_ask(asked: QueryOptions.Query) -> RefsAsk
  if asked.stdin != ""
    case QueryPosition.parse(asked.stdin, REFS_USAGE)
      QueryPosition.Parsed.Ready(position) -> return RefsAsk.At(position, asked.words)
      QueryPosition.Parsed.Refused(_) -> return word_ask(asked.words)
    end
  end
  return word_ask(asked.words)
end

## `agentica refs` for the position `asked`, linked together with the files of `paths` and checked as `type_at` checks.
## It lists the references to the name at the position, or is QUERY-NO-EXPRESSION when the position names nothing.
export def refs_at(
  asked: QueryPosition.Asked,
  paths: List[String],
  style: String,
  settings: Env.Settings,
) -> Reply.Answer
  return refs_reply(Core.refs_at(settings, asked, paths, REFS_USAGE), style, asked.file)
end

## `agentica refs` for a NAME, searched in the files of `paths` (`.` by default) and what they import. `buffer` is the
## FILE whose text the Workspace of `settings` holds as the standard input, if any; it is searched too.
export def refs_named(
  name: String,
  paths: List[String],
  buffer: String,
  style: String,
  settings: Env.Settings,
) -> Reply.Answer
  return refs_reply(Core.refs_named(settings, name, paths, buffer, REFS_USAGE), style, buffer)
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

# The first word is a position when it has a colon, else a name.
def word_ask(words: List[String]) -> RefsAsk
  if words.size == 0 or words[0] == ""
    return RefsAsk.Refused(QueryOptions.refusal("missing NAME or FILE:LINE:COL", REFS_USAGE))
  elsif !words[0].contains?(":")
    return RefsAsk.Named(words[0], words.drop(1))
  end
  case QueryPosition.parse(words[0], REFS_USAGE)
    QueryPosition.Parsed.Refused(problem) -> return RefsAsk.Refused(problem)
    QueryPosition.Parsed.Ready(position) -> return RefsAsk.At(position, words.drop(1))
  end
end

# The reply for an answer of `refs`: in the text form the files left out are one line each on stderr.
def refs_reply(found: Core.Referenced, style: String, file: String) -> Reply.Answer
  case found
    Core.Referenced.Unreadable -> return Reply.Answer.Rejected(QueryFiles.unreadable(file, REFS_USAGE))
    Core.Referenced.Rejected(problem) -> return Reply.Answer.Rejected(problem)
    Core.Referenced.Done(answer) ->
      if style == "json"
        return Reply.Answer.Printed(Reply.printed("#{JSON.encode(RefsJson.json(answer))}\n"))
      end
      return Reply.Answer.Printed(
        Reply.Reply(code: 0, out: RefsText.text(answer), err: RefsText.skipped_text(answer)),
      )
  end
end
