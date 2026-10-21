## The words of a query command (docs/future/39-semantic-cli.md, 39.2) after the command, read by hand as `help` and
## `doc` read theirs: `--json`, `--ai`, `--stdin FILE` and, for the commands that answer from a program that does not
## check, `--partial` may stand among the arguments, in any order; every other word that starts with "-" and has more
## than one character is an unknown option. The options in front of the command were
## read by the command line already (app/cli_options.agc); the last style written wins.
##
## A mistake in the words is the diagnostic QUERY-USAGE, located at the pseudo-file `<arguments>` (line 1, column 1),
## as the usage error of `agentica test` is (RUNTIME-BDD-USAGE): a name typed on the command line has no place in a
## file. It carries the usage line of the command as its help.

import Diag from "../diagnostics/diagnostic"
import Problems from "../diagnostics/problem"
import Source from "../syntax/source"

# The file of every QUERY-USAGE diagnostic.
ARGUMENTS = "<arguments>"

## What the words said. `style` is "plain", "ai" or "json". `stdin` is the FILE of `--stdin` ("" without it): the text
## of that file is the standard input. `partial` is whether `--partial` was given. `words` are the arguments that are
## not options, in order.
export struct Query
  style: String
  stdin: String
  partial: Bool
  words: List[String]
end

## The words of a query, or why they are wrong.
export enum Parsed
  Ready(Query)
  Refused(Problems.Problem)
end

## Reads `arguments`, the words after the command. `style` is the one the options in front of the command gave, and
## `usage` the usage line of the command, which a refusal gives as its help. `partial_wanted` is whether the command
## has the option `--partial`; for another it is an unknown option.
export def parse(arguments: List[String], style: String, usage: String, partial_wanted: Bool) -> Parsed
  query = Query(style: style, stdin: "", partial: false, words: [])
  at = 0
  while at < arguments.size
    word = arguments[at]
    if word == "--json"
      query = query.with(style: "json")
    elsif word == "--ai"
      query = query.with(style: "ai")
    elsif word == "--partial" and partial_wanted
      query = query.with(partial: true)
    elsif word == "--stdin"
      if query.stdin != "" or at + 1 >= arguments.size or !file_name?(arguments[at + 1])
        return Parsed.Refused(refusal("--stdin needs one FILE, once", usage))
      end
      query = query.with(stdin: arguments[at + 1])
      at += 1
    elsif option?(word)
      return Parsed.Refused(refusal("unknown option #{word}", usage))
    else
      query = query.with(words: query.words.push(word))
    end
    at += 1
  end
  return Parsed.Ready(query)
end

## Whether `word` looks like an option: it starts with "-" and has more than one character. A lone "-" is a file name.
## `--stdin` refuses such a FILE, so `--stdin --json` does not take the option as the file.
export def option?(word: String) -> Bool
  return word.length > 1 and word.starts_with?("-")
end

## Whether `word` can be the FILE of `--stdin`: not empty and not an option.
export def file_name?(word: String) -> Bool
  return word != "" and !option?(word)
end

## Whether the problem is about the words of the command line (QUERY-USAGE), which no file holds.
export def arguments?(problem: Problems.Problem) -> Bool
  return problem.file == ARGUMENTS
end

## The problem with no place in a text (line 0), for `--ai`, which prints the source line of a place: it shows the file
## name alone, as the plain form does. The JSON form keeps the span of `refusal`.
export def unplaced(problem: Problems.Problem) -> Problems.Problem
  none = Source.Position(offset: 0, line: 0, column: 0)
  return problem.with(span: Source.Span(start: none, stop: none))
end

## The QUERY-USAGE diagnostic with `message`, and `usage` as its help.
export def refusal(message: String, usage: String) -> Problems.Problem
  return at_arguments("QUERY-USAGE", message, Diag.Help.Hint(usage))
end

## A QUERY- diagnostic about the words of the command line, located at the pseudo-file `<arguments>`.
export def at_arguments(code: String, message: String, help: Diag.Help) -> Problems.Problem
  start = Source.Position(offset: 0, line: 1, column: 1)
  span = Source.Span(start: start, stop: start)
  return Problems.problem(ARGUMENTS, "", code, message, span, help)
end
