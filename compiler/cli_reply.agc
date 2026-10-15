## What a command of the command line answers with: the exit code, the text for stdout and the text for stderr. The
## command does not print; cli.agc does, so every output of the tool is in one place.

## The answer of a command. `out` and `err` are written as they are: a line ends with "\n" in them.
export struct Reply
  code: Int
  out: String
  err: String
end

## Success, with `text` on stdout.
export def printed(text: String) -> Reply
  return Reply(code: 0, out: text, err: "")
end

## A failure with `code`, and `text` on stderr.
export def failed(code: Int, text: String) -> Reply
  return Reply(code: code, out: "", err: text)
end
