## `agentica doc PATH [--json]`: the exported API of one module with its `##` docs (docs/future/32-doc-comments.md,
## 32.5). PATH is a source file, read through the Workspace, or a `std/` module name, read from the provider of the
## settings (the copy the binary carries). The module is only lexed and parsed (docs/doc.agc), so it never needs its
## imports.

import Diag from "../diagnostics/diagnostic"
import Docs from "../docs/doc"
import DocJson from "../docs/doc_json"
import DocText from "../docs/doc_text"
import Env from "../modules/link_env"
import Pipeline from "pipeline"
import Problems from "../diagnostics/problem"
import Reply from "cli_reply"
import Resolve from "../modules/resolve_import"
import SourceFile from "../syntax/source_file"

## What the command gave: a complete answer (the text, a usage error, a file that cannot be read), or the first
## problem of the module, which cli.agc prints in the style of the options and answers with status 1.
export enum Answer
  Printed(Reply.Reply)
  Rejected(Problems.Problem)
end

## Runs `agentica doc` for `words`, the words from `doc` on, in the style `--json` or `--ai` gave in front of it. A
## trailing `--json` asks for the JSON form too, as it does for `help`.
export def run(words: List[String], style: String, settings: Env.Settings) -> Answer
  rest = words.drop(1)
  as_json = style == "json"
  if rest.size > 0 and rest[rest.size - 1] == "--json"
    as_json = true
    rest = rest.take(rest.size - 1)
  end
  if rest.size != 1 or rest[0] == ""
    return Answer.Printed(Reply.failed(2, "usage: agentica doc PATH [--json]\n"))
  end
  path = rest[0]
  case read(settings, path)
    SourceFile.Read.Unreadable(_) -> return Answer.Printed(Reply.failed(2, "agentica: cannot read #{path}\n"))
    SourceFile.Read.Invalid(at) -> return Answer.Rejected(Pipeline.stage_problem(path, SourceFile.invalid_utf8(at)))
    SourceFile.Read.Text(text) -> return documented(path, text, as_json)
  end
end

# A `std/` name is read from the provider of the settings, under the key of the module (`std/http.agc`); any other
# path is a file of the disk, as the user typed it.
def read(settings: Env.Settings, path: String) -> SourceFile.Read
  if path.starts_with?("std/")
    key = path
    if !path.ends_with?(".agc")
      key = "#{path}.agc"
    end
    return Resolve.read_source(settings, key)
  end
  return settings.workspace.read_text.call(path)
end

def documented(path: String, text: String, as_json: Bool) -> Answer
  case Docs.of_text(text)
    Diag.Outcome.Failed(problem) -> return Answer.Rejected(Pipeline.stage_problem(path, problem))
    Diag.Outcome.Done(module) ->
      if as_json
        return Answer.Printed(Reply.printed("#{JSON.encode(DocJson.json(path, module))}\n"))
      end
      return Answer.Printed(Reply.printed(DocText.text(path, module)))
  end
end
