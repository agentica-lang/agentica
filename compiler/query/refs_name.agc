## The declaration that `agentica refs NAME` selects (docs/future/39-semantic-cli.md, 39.3 and 39.4). The name is
## resolved by `symbol` (symbol.agc), so the two commands read a name alike; `symbol` lists every match, and `refs`
## needs exactly one, since a list of references belongs to one declaration. Two or more are QUERY-AMBIGUOUS-NAME, with
## the place of each candidate as `FILE:LINE:COL`, which is the position form of the command.

import Diag from "../diagnostics/diagnostic"
import Problems from "../diagnostics/problem"
import Env from "../modules/link_env"
import QueryFiles from "query_files"
import QueryOptions from "query_options"
import Symbol from "symbol"

## The match a name selects, or why it selects none.
export enum Picked
  One(Symbol.Match)
  Refused(Problems.Problem)
end

## The one declaration of `matches`, the answer of `symbol` for `name`. A declaration that several names reach counts
## once. The candidates of a refusal are named with the files as an answer names them.
export def pick(name: String, matches: List[Symbol.Match], settings: Env.Settings) -> Picked
  distinct = once(matches)
  if distinct.size == 1
    return Picked.One(distinct[0])
  end
  places = distinct.map do |found: Symbol.Match| place(settings, found) end
  help = Diag.Help.Hint("write FILE:LINE:COL of one of: #{places.join(", ")}")
  return Picked.Refused(
    QueryOptions.at_arguments("QUERY-AMBIGUOUS-NAME", "#{name} names #{distinct.size} declarations", help),
  )
end

## The refusal of `symbol` for `name`, with a note when the word ends in `.agc`: a file is not a name, and the position
## form takes `FILE:LINE:COL`.
export def not_found(name: String, problem: Problems.Problem) -> Problems.Problem
  if problem.code != "QUERY-NOT-FOUND" or !name.ends_with?(".agc")
    return problem
  end
  note = "#{name} is a file; to ask about a place in it write #{name}:LINE:COL"
  case problem.help
    Diag.Help.Hint(text) -> return problem.with(help: Diag.Help.Hint("#{text}; #{note}"))
    Diag.Help.NoHelp -> return problem.with(help: Diag.Help.Hint(note))
  end
end

# The matches without a second one for the same name in the same file.
def once(matches: List[Symbol.Match]) -> List[Symbol.Match]
  out: List[Symbol.Match] = []
  for found in matches
    if !out.any? do |kept: Symbol.Match| same?(kept, found) end
      out = out.push(found)
    end
  end
  return out
end

def same?(left: Symbol.Match, right: Symbol.Match) -> Bool
  same_place = left.file == right.file and left.name_span.start.offset == right.name_span.start.offset
  return same_place and left.kind == right.kind
end

# `FILE:LINE:COL` of the name of the declaration; a builtin has no place, so its name stands for it.
def place(settings: Env.Settings, found: Symbol.Match) -> String
  if found.file == ""
    return found.name
  end
  start = found.name_span.start
  return "#{QueryFiles.display(settings, found.file, true)}:#{start.line}:#{start.column}"
end
