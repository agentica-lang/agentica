## `agentica help`: the summary of the commands and the namespaces of the builtins, or the signature and description
## of one builtin (as text, or as JSON with `--json`). It reads the builtin catalog (builtins.agc), the one description
## of the builtins.

import Ast from "../syntax/ast"
import Model from "../catalog/builtin_model"
import Builtins from "../catalog/builtins"
import Reply from "cli_reply"
import Texts from "cli_text"
import Suggest from "../syntax/suggest"
import Types from "../syntax/types"
import {PRELUDE_ONLY, PUBLIC_NAMES} from "../catalog/builtins"

## Runs `agentica help` for `words`, the words from `help` on, in the style `--json` or `--ai` gave in front of it.
## A trailing `--json` asks for the JSON form: of the one builtin, or of every public builtin as an array (sorted by
## name, each element as `help NAME --json` prints it) when there is no NAME. Nothing else takes an option.
export def help(words: List[String], style: String) -> Reply.Reply
  rest = words
  as_json = style == "json"
  if rest.size > 0 and rest[rest.size - 1] == "--json"
    as_json = true
    rest = rest.take(rest.size - 1)
  end
  if rest.size == 1 and as_json
    return Reply.printed("#{JSON.encode(catalog_json())}\n")
  elsif rest.size == 1
    return Reply.printed("#{Texts.summary_text()}#{namespaces_text()}\n")
  elsif rest.size != 2
    return Reply.failed(2, "usage: agentica help [NAME] [--json]\n")
  end
  name = rest[1]
  entry = Builtins.lookup(name)
  if Builtins.std_only_name?(name) or PRELUDE_ONLY.include?(name) or !entry.ok?
    return Reply.failed(2, "agentica: unknown builtin #{name}#{suggestion(name)}\n")
  end
  if as_json
    return Reply.printed("#{JSON.encode(builtin_json(entry.unwrap!))}\n")
  end
  return Reply.printed("#{Builtins.signature(entry.unwrap!)}\n#{entry.unwrap!.description}\n")
end

# `; did you mean "NAME"?` when a public name is close, else nothing.
def suggestion(name: String) -> String
  case Suggest.did_you_mean(name, PUBLIC_NAMES)
    Ast.Optional.Present(text) -> return "; #{text}"
    Ast.Optional.Absent -> return ""
  end
end

# The paragraph that follows the summary: the namespaces (the part of a name before its first dot, sorted) and the
# bare functions.
def namespaces_text() -> String
  names = PUBLIC_NAMES.sort
  spaces: List[String] = []
  bare: List[String] = []
  for name in names
    dot = name.index_of(".")
    if !dot.ok?
      bare = bare.push(name)
    elsif spaces.size == 0 or spaces[spaces.size - 1] != name.slice(0, dot.unwrap!)
      spaces = spaces.push(name.slice(0, dot.unwrap!))
    end
  end
  return [
    "Builtins: agentica help NAME prints one signature (NAME is Namespace.function, or a bare function).",
    "  namespaces: #{spaces.join(" ")}",
    "  bare functions: #{bare.join(" ")}",
    [
      "  std modules written in Agentica (import \"std/http\", \"std/queue\", \"std/binary\", \"std/toml\", ",
      "\"std/bdd\") are not in this catalog.",
    ].join(""),
  ].join("\n")
end

# Every public builtin, in name order, each as `builtin_json` gives it, so a client reads both forms with one parser.
def catalog_json() -> Json
  # `unwrap!` cannot fail: PUBLIC_NAMES are keys of the same ENTRIES that `Builtins.lookup` reads.
  return JSON.array(PUBLIC_NAMES.sort.map do |name: String| builtin_json(Builtins.lookup(name).unwrap!) end)
end

# The JSON of a builtin: one object for a builtin with one form, else the name, the description and the effects of the
# first form with the object of each form under `overloads`.
def builtin_json(entry: Model.Builtin) -> Json
  if entry.alternatives.size == 0
    return form_json(entry)
  end
  forms = [entry].concat(entry.alternatives)
  return JSON.object({
    "name": JSON.from(entry.name),
    "description": JSON.from(entry.description),
    "effects": strings(entry.effects),
    "overloads": JSON.array(forms.map do |form: Model.Builtin| form_json(form) end),
  })
end

def form_json(form: Model.Builtin) -> Json
  parameters = form.parameters.map do |parameter: Model.Named|
    JSON.object({"name": JSON.from(parameter.name), "type": JSON.from(Types.to_text(parameter.type))})
  end
  return JSON.object({
    "name": JSON.from(form.name),
    "arity": JSON.from(form.parameters.size),
    "parameters": JSON.array(parameters),
    "result": JSON.from(Types.to_text(form.result)),
    "signature": JSON.from(Builtins.form_signature(form)),
    "effects": strings(form.effects),
    "description": JSON.from(form.description),
  })
end

def strings(items: List[String]) -> Json
  return JSON.array(items.map do |item: String| JSON.from(item) end)
end
