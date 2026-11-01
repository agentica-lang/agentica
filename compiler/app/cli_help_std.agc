## `agentica help std/MODULE[.NAME] [--json]`: what a module of the standard library exports, or one export, with its
## `##` docs (docs/future/32-doc-comments.md, 32.6). The module is read as `agentica doc` reads it (cli_doc.agc): from
## the copy the binary carries, lexed and parsed only. A MODULE lists its exports with their summaries; a NAME prints
## the signature, the whole doc and the fields or variants. A module or name that does not exist is QUERY-NOT-FOUND
## (exit 2), with a "did you mean" over the exports for a name.

import Convert from "../analysis/convert"
import Front from "../analysis/front"
import Diag from "../diagnostics/diagnostic"
import Problems from "../diagnostics/problem"
import Docs from "../docs/doc"
import DocJson from "../docs/doc_json"
import DocModel from "../docs/doc_model"
import DocText from "../docs/doc_text"
import Env from "../modules/link_env"
import QueryFiles from "../query/query_files"
import QueryOptions from "../query/query_options"
import Suggest from "../syntax/suggest"
import SourceFile from "../syntax/source_file"
import Reply from "cli_reply"

# The usage line of a QUERY-USAGE from this command.
USAGE = "usage: agentica help std/MODULE[.NAME] [--json]"

## Whether `words`, the words from `help` on, ask for a module of the standard library: one word that starts with
## `std/`, with or without a trailing `--json`. No builtin name starts that way.
export def asks?(words: List[String]) -> Bool
  rest = unflagged(words)
  return rest.size == 2 and rest[1].starts_with?("std/")
end

## Runs `agentica help std/...` for `words`, the words from `help` on, in the style `--json` or `--ai` gave in front of
## it. Call it only when `asks?` is true.
export def run(words: List[String], style: String, settings: Env.Settings) -> Reply.Answer
  as_json = style == "json" or (words.size > 0 and words[words.size - 1] == "--json")
  asked = unflagged(words)[1]
  dot = asked.index_of(".")
  path = asked
  name = ""
  if dot.some?
    path = asked.slice(0, dot.unwrap!)
    name = asked.slice(dot.unwrap! + 1, asked.length - dot.unwrap! - 1)
    if name == ""
      return Reply.Answer.Rejected(QueryOptions.refusal("missing name after #{path}.", USAGE))
    end
  end

  case QueryFiles.read(settings, path, false)
    SourceFile.Read.Unreadable(_) -> return Reply.Answer.Rejected(unknown_module(path))
    SourceFile.Read.Invalid(at) -> return Reply.Answer.Rejected(Front.stage_problem(path, SourceFile.invalid_utf8(at)))
    SourceFile.Read.Text(text) -> return answered(settings, path, name, text, as_json)
  end
end

# The words of `help` without a trailing `--json`.
def unflagged(words: List[String]) -> List[String]
  if words.size > 0 and words[words.size - 1] == "--json"
    return words.take(words.size - 1)
  end

  return words
end

def answered(settings: Env.Settings, path: String, name: String, text: String, as_json: Bool) -> Reply.Answer
  case Docs.of_file(settings, path, text)
    Diag.Outcome.Failed(problem) -> return Reply.Answer.Rejected(Front.stage_problem(path, problem))
    Diag.Outcome.Done(module) ->
      if name == ""
        return Reply.Answer.Printed(module_reply(path, module, as_json))
      end

      found = module.items.filter do |item: DocModel.Item| item.name == name end
      if found.size == 0
        return Reply.Answer.Rejected(unknown_name(path, name, module))
      end

      return Reply.Answer.Printed(item_reply(path, found[0], as_json))
  end
end

def unknown_module(path: String) -> Problems.Problem
  message = "#{path} is not a module of the standard library"
  return QueryOptions.at_arguments("QUERY-NOT-FOUND", message, Diag.Help.Hint(USAGE))
end

def unknown_name(path: String, name: String, module: DocModel.Module) -> Problems.Problem
  names = module.items.map do |item: DocModel.Item| item.name end
  help = Diag.Help.Hint("agentica help #{path} lists its exports")
  case Suggest.did_you_mean(name, names)
    some(text) -> help = Diag.Help.Hint(text)
    none -> help = help
  end

  return QueryOptions.at_arguments("QUERY-NOT-FOUND", "#{path} exports no #{name}", help)
end

# The list of a module: `{module, doc, items: [{kind, name, summary}]}`, or its path and doc and then each export as
# its signature with its summary under it.
def module_reply(path: String, module: DocModel.Module, as_json: Bool) -> Reply.Reply
  if as_json
    items = module.items.map do |item: DocModel.Item|
      JSON.object({
        "kind": JSON.from(item.kind),
        "name": JSON.from(item.name),
        "summary": DocJson.text_json(summary_of(item)),
      })
    end

    answer = JSON.object({
      "module": JSON.from(path),
      "doc": DocJson.text_json(text_of(module.doc)),
      "items": JSON.array(items),
    })
    return Reply.printed("#{JSON.encode(answer)}\n")
  end

  blocks = [path]
  case module.doc
    some(doc) -> blocks = blocks.push(doc)
    none -> blocks = blocks
  end

  lines = module.items.map do |item: DocModel.Item| list_line(item) end

  if lines.size > 0
    blocks = blocks.push(lines.join("\n"))
  end

  return Reply.printed("#{blocks.join("\n\n")}\n")
end

# One export. As JSON it has the fields of `help NAME --json` for a builtin that apply (`name`, `arity`, `parameters`,
# `result`, `signature`, `description` as the whole doc or null) and `summary`, with `kind`, and the `fields` of a
# struct or the `variants` of an enum. As text it is the signature, the doc, and a list line per field or variant.
def item_reply(path: String, item: DocModel.Item, as_json: Bool) -> Reply.Reply
  if as_json
    return Reply.printed("#{JSON.encode(DocJson.help_json(path, Convert.item(item)))}\n")
  end

  blocks = [item.signature]
  case item.doc
    some(doc) -> blocks = blocks.push(doc)
    none -> blocks = blocks
  end

  parts = DocText.part_lines(item.detail)
  if parts.size > 0
    blocks = blocks.push(parts.join("\n"))
  end

  return Reply.printed("#{blocks.join("\n")}\n")
end

# The signature of an export, and its summary under it when it has one.
def list_line(item: DocModel.Item) -> String
  case DocModel.summary(item.doc)
    some(summary) -> return "  #{item.signature}\n      #{summary}"
    none -> return "  #{item.signature}"
  end
end

def summary_of(item: DocModel.Item) -> String
  return text_of(DocModel.summary(item.doc))
end

def text_of(doc: Optional[String]) -> String
  case doc
    some(text) -> return text
    none -> return ""
  end
end
