## What `agentica fmt` says (docs/future/47-formatter.md, phase 47b): the usage line and what the formatter makes of
## one file. Reading the files and printing is cli.agc's, which owns the output.
##
## `fmt --check [PATH...]` lists the files that formatting would change, one per line, and gives 1 when there are any;
## a file that does not parse prints its diagnostic and counts as failed. `fmt --tree FILE` prints the normal form of
## 47.7, which the tests compare before and after formatting. Writing the files comes with phase 47c.

import Diag from "../diagnostics/diagnostic"
import Format from "../format/format"

# The usage line of `fmt`.
USAGE = "usage: agentica fmt --check [PATH...]   or   agentica fmt --tree FILE"

## What formatting one file gives: no change, a change, or the diagnostic that refuses it.
export enum Verdict
  Same
  Changed
  Refused(Diag.Diagnostic)
end

## The usage line of `agentica fmt`.
export def usage() -> String
  return USAGE
end

## What formatting `text` gives, in the default width. A text whose bytes differ from the output is changed, so a
## CRLF file is.
export def verdict(text: String) -> Verdict
  case Format.format_text(text, Format.WIDTH)
    Diag.Outcome.Failed(problem) -> return Verdict.Refused(problem)
    Diag.Outcome.Done(output) ->
      if output == text
        return Verdict.Same
      end

      return Verdict.Changed
  end
end

## The normal form of `text`, or the diagnostic of a text that does not parse.
export def tree(text: String) -> Diag.Outcome[String]
  return Format.tree_text(text)
end
