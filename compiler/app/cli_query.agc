## The query commands (docs/future/39-semantic-cli.md): `agentica outline FILE [--json] [--partial] [--stdin FILE]`,
## `agentica type-at FILE:LINE:COL [--json] [--partial]` (reads FILE from standard input with `--stdin FILE:LINE:COL`),
## `agentica symbol NAME [PATH...] [--json] [--stdin FILE]` and `agentica refs NAME|FILE:LINE:COL [PATH...] [--json]
## [--partial]`, which takes `--stdin` as `type-at` for a position and as `symbol` for a name. A query reads its file
## through the Workspace of the settings, which is the standard input for `--stdin` (cli.agc, `with_buffer`), and
## answers in text or in JSON. `outline` never links or checks, so the imports of the file need not exist; `type-at`
## links and checks the file and what it imports, without requiring `main`; `symbol` and `refs` link the files of their
## paths together and list the ones that do not link, and `refs` checks the program too.
##
## With `--partial`, `type-at` and `refs FILE:LINE:COL` (alone: not with a NAME or PATH...) also answer from a program
## in which some functions do not check (39.6): the answer has `partial` and `diagnostics` in the JSON form, one line
## on stderr for each diagnostic in the text form, and the exit status is 0. A program that checks gets the answer it
## gets without the option. `outline` takes the option and has nothing to add: it never checks.
##
## A mistake in the question is a QUERY- diagnostic and exit status 2; a diagnostic of the file (lexer, parser, linker
## or checker) is exit status 1 (cli.agc prints both).

import Core from "../analysis/analysis"
import Cache from "../analysis/cache"
import DiagnosticModel from "../diagnostics/diagnostic_model"
import Problems from "../diagnostics/problem"
import Env from "../modules/link_env"
import OutlineJson from "../query/outline_json"
import OutlineText from "../query/outline_text"
import QueryFiles from "../query/query_files"
import QueryOptions from "../query/query_options"
import QueryPosition from "../query/query_position"
import RefsJson from "../query/refs_json"
import RefsText from "../query/refs_text"
import SymbolJson from "../query/symbol_json"
import SymbolText from "../query/symbol_text"
import TypeAtJson from "../query/type_at_json"
import TypeAtText from "../query/type_at_text"
import Reply from "cli_reply"

# The usage line of each query command, given as the help of QUERY-USAGE.
OUTLINE_USAGE = (
  "usage: agentica outline FILE [--json] [--partial]   or   " + "agentica outline --stdin FILE [--json] [--partial]"
)
TYPE_AT_USAGE = (
  "usage: agentica type-at FILE:LINE:COL [--json] [--partial]   or   " +
  "agentica type-at --stdin FILE:LINE:COL [--json] [--partial]"
)
REFS_USAGE = (
  "usage: agentica refs NAME [PATH...] [--json]   or   " +
  "agentica refs FILE:LINE:COL [PATH...] [--json] [--partial]   or   " +
  "agentica refs --stdin FILE:LINE:COL [PATH...] [--json] [--partial]"
)
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
## expression is QUERY-NO-EXPRESSION. With `partial`, a program in which some functions do not check is answered too
## (`Core.type_at_partial`).
export def type_at(asked: QueryPosition.Asked, style: String, partial: Bool, settings: Env.Settings) -> Reply.Answer
  asking: Core.Typed = Core.Typed.Unreadable
  if partial
    asking = Core.type_at_partial(Cache.empty(), settings, asked)
  else
    asking = Core.type_at(Cache.empty(), settings, asked)
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

## Reads the words of `refs`. The first word is `FILE:LINE:COL` or a NAME, and the others are paths; `--stdin
## FILE:LINE:COL` stands in for the first word. A word with a colon is a position, which a name never has, so a bad
## position is QUERY-USAGE and not a name that nothing declares. `--partial` answers a position alone, so a NAME or a
## path with it is QUERY-USAGE.
export def refs_ask(asked: QueryOptions.Query) -> RefsAsk
  found = positioned(asked)
  case found
    RefsAsk.At(_, paths) ->
      if asked.partial and paths.size > 0
        return RefsAsk.Refused(QueryOptions.refusal("--partial takes FILE:LINE:COL alone", REFS_USAGE))
      end

      return found
    RefsAsk.Named(_, _) ->
      if asked.partial
        return RefsAsk.Refused(QueryOptions.refusal("--partial takes FILE:LINE:COL, not a NAME", REFS_USAGE))
      end

      return found
    RefsAsk.Refused(_) -> return found
  end
end

## `agentica refs` for the position `asked`, linked together with the files of `paths` and checked as `type_at` checks.
## It lists the references to the name at the position, or is QUERY-NO-EXPRESSION when the position names nothing. With
## `partial` (and no `paths`: `refs_ask` has refused the others) a program in which some functions do not check is
## answered too (`Core.refs_partial`).
export def refs_at(
  asked: QueryPosition.Asked,
  paths: List[String],
  style: String,
  partial: Bool,
  settings: Env.Settings,
) -> Reply.Answer
  if partial
    return refs_reply(Core.refs_partial(Cache.empty(), settings, asked), style, asked.file)
  end

  return refs_reply(Core.refs_at(Cache.empty(), settings, asked, paths, REFS_USAGE), style, asked.file)
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
  return refs_reply(Core.refs_named(Cache.empty(), settings, name, paths, buffer, REFS_USAGE), style, buffer)
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

  case Core.symbol(Cache.empty(), settings, name, asked.words.drop(1), asked.stdin, SYMBOL_USAGE)
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

# The words as a position or a name, whatever `--partial` says.
def positioned(asked: QueryOptions.Query) -> RefsAsk
  if asked.stdin != ""
    case QueryPosition.parse(asked.stdin, REFS_USAGE)
      QueryPosition.Parsed.Ready(position) -> return RefsAsk.At(position, asked.words)
      QueryPosition.Parsed.Refused(_) -> return word_ask(asked.words)
    end
  end

  return word_ask(asked.words)
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

# The reply for an answer of `refs`: in the text form the files left out and the problems of a partial answer are one
# line each on stderr.
def refs_reply(found: Core.Referenced, style: String, file: String) -> Reply.Answer
  case found
    Core.Referenced.Unreadable -> return Reply.Answer.Rejected(QueryFiles.unreadable(file, REFS_USAGE))
    Core.Referenced.Rejected(problem) -> return Reply.Answer.Rejected(problem)
    Core.Referenced.Done(answer) ->
      if style == "json"
        return Reply.Answer.Printed(Reply.printed("#{JSON.encode(RefsJson.json(answer))}\n"))
      end

      return Reply.Answer.Printed(
        Reply.Reply(
          code: 0,
          out: RefsText.text(answer),
          err: RefsText.skipped_text(answer) + partial_text(answer.diagnostics),
        ),
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
