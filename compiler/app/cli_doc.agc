## `agentica doc PATH [--json]`: the exported API of one module with its `##` docs (docs/future/32-doc-comments.md,
## 32.5). PATH is a source file, read through the Workspace, or a `std/` module name, read from the provider of the
## settings (the copy the binary carries). The module is only lexed and parsed (docs/doc.agc), so it never needs its
## imports.

import Front from "../analysis/front"
import Diag from "../diagnostics/diagnostic"
import Docs from "../docs/doc"
import DocJson from "../docs/doc_json"
import DocText from "../docs/doc_text"
import Env from "../modules/link_env"
import QueryFiles from "../query/query_files"
import SourceFile from "../syntax/source_file"
import Reply from "cli_reply"

## Runs `agentica doc` for `words`, the words from `doc` on, in the style `--json` or `--ai` gave in front of it. A
## trailing `--json` asks for the JSON form too, as it does for `help`.
export def run(words: List[String], style: String, settings: Env.Settings) -> Reply.Answer
  rest = words.drop(1)
  as_json = style == "json"
  if rest.size > 0 and rest[rest.size - 1] == "--json"
    as_json = true
    rest = rest.take(rest.size - 1)
  end
  if rest.size != 1 or rest[0] == ""
    return Reply.Answer.Printed(Reply.failed(2, "usage: agentica doc PATH [--json]\n"))
  end
  path = rest[0]
  case QueryFiles.read(settings, path, false)
    SourceFile.Read.Unreadable(_) -> return Reply.Answer.Printed(Reply.failed(2, "agentica: cannot read #{path}\n"))
    SourceFile.Read.Invalid(at) ->
      return Reply.Answer.Rejected(Front.stage_problem(path, SourceFile.invalid_utf8(at)))
    SourceFile.Read.Text(text) -> return documented(path, text, as_json)
  end
end

def documented(path: String, text: String, as_json: Bool) -> Reply.Answer
  case Docs.of_text(text)
    Diag.Outcome.Failed(problem) -> return Reply.Answer.Rejected(Front.stage_problem(path, problem))
    Diag.Outcome.Done(module) ->
      if as_json
        return Reply.Answer.Printed(Reply.printed("#{JSON.encode(DocJson.json(path, module))}\n"))
      end
      return Reply.Answer.Printed(Reply.printed(DocText.text(path, module)))
  end
end
