## `agentica help`: the summary of the commands and the namespaces of the builtins, or the signature and description
## of one builtin (as text, or as JSON with `--json`). It reads the builtin catalog (builtins.agc), the one description
## of the builtins.

import Builtins from "../catalog/builtins"
import {CALLABLE_NAMES, PUBLIC_NAMES} from "../catalog/builtins"
import Model from "../catalog/builtin_model"
import RubyForm from "../check/ruby_form"
import CatalogJson from "../catalog/catalog_json"
import Tables from "../check/check_tables"
import Ast from "../syntax/ast"
import Suggest from "../syntax/suggest"
import Alias from "cli_alias"
import Reply from "cli_reply"
import Texts from "cli_text"

## Runs `agentica help` for `words`, the words from `help` on, in the style `--json` or `--ai` gave in front of it.
## A trailing `--json` asks for the JSON form: of the one builtin, or of every public builtin as an array (sorted by
## name, each element as `help NAME --json` prints it) when there is no NAME. Nothing else takes an option.
## A NAME that is not a builtin but a name from another language (`strip`, `String.to_i`, `value!`) answers with the
## builtins it stands for (cli_alias.agc), each under a line such as "`NAME` is written `.strip`" when NAME is not how
## Ruby writes it, then the hints of the checker for that name on other types; as JSON it is {"alias": NAME,
## "builtins": [the object of each builtin], "hints": {"Kind.name": text}}. A name with a foreign-language hint of its
## own (`int`) gets that hint and exit 2.
export def help(words: List[String], style: String) -> Reply.Reply
  rest = words
  as_json = style == "json"
  if rest.size > 0 and rest[rest.size - 1] == "--json"
    as_json = true
    rest = rest.take(rest.size - 1)
  end

  if rest.size == 1 and as_json
    return Reply.printed("#{JSON.encode(CatalogJson.catalog(&RubyForm.signature))}\n")
  elsif rest.size == 1
    return Reply.printed("#{Texts.summary_text()}#{namespaces_text()}\n")
  elsif rest.size != 2
    return Reply.failed(2, "usage: agentica help [NAME] [--json]\n")
  end

  name = rest[1]
  entry = CatalogJson.public(name)
  if !entry.ok?
    return renamed(name, as_json)
  end

  if as_json
    return Reply.printed("#{JSON.encode(CatalogJson.builtin(entry.unwrap!, &RubyForm.signature))}\n")
  end

  return Reply.printed(block(name, entry.unwrap!))
end

# The answer for a name that is no builtin: the hint of the checker for a name from another language that has one
# (`int`, `Hash.new`: its targets could mislead), else the builtins it stands for, else the unknown-builtin error.
def renamed(name: String, as_json: Bool) -> Reply.Reply
  found: List[String] = []
  if !Tables.foreign_names().has_key?(name)
    found = Alias.targets(name)
  end

  if found.size == 0
    return Reply.failed(2, "agentica: unknown builtin #{name}#{suggestion(name)}\n")
  end

  # `unwrap!` cannot fail: targets keeps only public builtins.
  entries = found.map do |target: String| CatalogJson.public(target).unwrap! end
  hints = Alias.kind_hints(name)
  if as_json
    answer = JSON.object({
      "alias": JSON.from(name),
      "builtins": JSON.array(
        entries.map do |entry: Model.Builtin| CatalogJson.builtin(entry, &RubyForm.signature) end,
      ),
      "hints": JSON.from(hints),
    })
    return Reply.printed("#{JSON.encode(answer)}\n")
  end

  blocks = entries.map do |entry: Model.Builtin| block(name, entry) end
  notes = hints.keys.sort.map do |key: String| "#{key}: #{hints[key]}\n" end
  return Reply.printed(blocks.concat(notes).join("\n"))
end

# The text of one builtin for the name asked: a line when the name is not how Ruby writes it, then the signature of
# each form in the Ruby method form (`s.strip() -> String`) when the builtin has one, then the description.
def block(name: String, entry: Model.Builtin) -> String
  written = RubyForm.method_name(entry.name)
  forms = [entry].concat(entry.alternatives).map do |form: Model.Builtin| form_text(form, written) end
  return "#{rename_line(name, entry.name, written)}#{forms.join("\n")}\n#{entry.description}\n"
end

# The signature of a form: in the Ruby form with the method name `method`, else as the catalog has it.
def form_text(form: Model.Builtin, method: String) -> String
  ruby = RubyForm.signature_as(form, method)
  if ruby == ""
    return Builtins.form_signature(form)
  end

  return ruby
end

# "`String.trim` is written `.strip`" when `name` is not how Ruby writes the builtin, "`strip` is called `Y` in
# Agentica" for a rename of a builtin that has no Ruby form, else nothing. `written` is the method the form is shown
# with. A name asked without its type gets the type of `target`, so `help include?` says which type writes `.key?`.
def rename_line(name: String, target: String, written: String) -> String
  asked = name.split(".")
  method = asked[asked.size - 1]
  own = target.split(".")
  if written != ""
    if method == written
      return ""
    end

    typed = name
    if asked.size == 1 and own.size > 1
      typed = "#{own[0]}.#{name}"
    end

    return "`#{typed}` is written `.#{written}`\n"
  end

  if method == own[own.size - 1]
    return ""
  end

  return "`#{name}` is called `#{target}` in Agentica\n"
end

# `; HINT` when the checker has help for this foreign name (`Hash.new`, `String.chomp`, `select`), else `; did you
# mean "NAME"?` when a public name is close, else nothing.
def suggestion(name: String) -> String
  hint = Tables.foreign_names().get(name)
  if !hint.ok?
    hint = Tables.foreign_kind_methods().get(name)
  end

  if hint.ok?
    return "; #{hint.unwrap!}"
  end

  hints = Alias.kind_hints(name)
  if hints.size > 0
    return "; " + hints.keys.sort.map do |key: String| "#{key}: #{hints[key]}" end.join("; ")
  end

  case Suggest.closest_among(name, CALLABLE_NAMES, [])
    Ast.Maybe.Present(found) -> return "; did you mean \"#{RubyForm.shown(found)}\"?"
    Ast.Maybe.Absent -> return ""
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
