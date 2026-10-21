## What a command of the command line answers with: the exit code, the text for stdout and the text for stderr. The
## command does not print; cli.agc does, so every output of the tool is in one place.

import Problems from "../diagnostics/problem"

## The answer of a command. `out` and `err` are written as they are: a line ends with "\n" in them.
export struct Reply
  code: Int
  out: String
  err: String
end

## What a command that reads a program gave: a complete answer (the text, a usage error, a file that cannot be read),
## or the first problem of the program, which cli.agc prints in the style of the options.
export enum Answer
  Printed(Reply)
  Rejected(Problems.Problem)
end

## Success, with `text` on stdout.
export def printed(text: String) -> Reply
  return Reply(code: 0, out: text, err: "")
end

## A failure with `code`, and `text` on stderr.
export def failed(code: Int, text: String) -> Reply
  return Reply(code: code, out: "", err: text)
end
