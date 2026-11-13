## `agentica help`: the summary of the commands and the namespaces of the builtins, or the signature and description
## of one builtin (as text, or as JSON with `--json`). It reads the builtin catalog (builtins.agc), the one description
## of the builtins.

import Builtins from "../catalog/builtins"
import {CALLABLE_NAMES, OPERATOR_ONLY, PUBLIC_NAMES} from "../catalog/builtins"
import Model from "../catalog/builtin_model"
import RubyForm from "../check/ruby_form"
import CatalogJson from "../catalog/catalog_json"
import Tables from "../check/check_tables"
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
def help(words: List[String], style: String) -> Reply.Reply
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
    return Reply.failed(2, "usage: agentica help [NAME|std/MODULE[.NAME]] [--json]\n")
  end

  name = rest[1]
  entry = CatalogJson.public(name)
  return renamed(name, as_json) if !entry.ok?

  return Reply.printed("#{JSON.encode(CatalogJson.builtin(entry.unwrap!, &RubyForm.signature))}\n") if as_json

  Reply.printed(block(name, entry.unwrap!))
end

private

# The answer for a name that is no builtin: the hint of the checker for a name from another language that has one
# (`int`, `Hash.new`: its targets could mislead), else the builtins it stands for, else the unknown-builtin error.
# A builtin written as an operator (List.concat is `+`) answers with that operator.
def renamed(name: String, as_json: Bool) -> Reply.Reply
  return operator_form(name, as_json) if OPERATOR_ONLY.include?(name)

  found: List[String] = []
  if !Tables.foreign_names().has_key?(name)
    found = Alias.targets(name)
  end

  return Reply.failed(2, "agentica: unknown builtin #{name}#{suggestion(name)}\n") if found.size == 0

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
  Reply.printed(blocks.concat(notes).join("\n"))
end

# "`List.concat` is written with an operator" and the checker's hint that names it; as JSON the alias shape with no
# builtins and that hint.
def operator_form(name: String, as_json: Bool) -> Reply.Reply
  hint = Tables.foreign_kind_methods().get(name).unwrap_or("")
  if as_json
    hints: Map[String, String] = {}
    answer = JSON.object({
      "alias": JSON.from(name),
      "builtins": JSON.array([]),
      "hints": JSON.from(hints.put(name, hint)),
    })

    return Reply.printed("#{JSON.encode(answer)}\n")
  end

  Reply.printed("`#{name}` is written with an operator\n#{name}: #{hint}\n")
end

# The text of one builtin for the name asked: a line when the name is not how Ruby writes it, then the signature of
# each form in the Ruby method form (`s.strip() -> String`) when the builtin has one, then the description.
def block(name: String, entry: Model.Builtin) -> String
  written = RubyForm.method_name(entry.name)
  forms = [entry].concat(entry.alternatives).map do |form: Model.Builtin| form_text(form, written) end
  "#{rename_line(name, entry.name, written)}#{forms.join("\n")}\n#{entry.description}\n"
end

# The signature of a form: in the Ruby form with the method name `method`, else as the catalog has it.
def form_text(form: Model.Builtin, method: String) -> String
  ruby = RubyForm.signature_as(form, method)
  return Builtins.form_signature(form) if ruby == ""

  ruby
end

# "`List.filter` is written `.select`" when `name` is not how Ruby writes the builtin, "`strip` is called `Y` in
# Agentica" for a rename of a builtin that has no Ruby form, else nothing. `written` is the method the form is shown
# with. A name asked without its type gets the type of `target`, so `help include?` says which type writes `.key?`.
def rename_line(name: String, target: String, written: String) -> String
  asked = name.split(".")
  method = asked[asked.size - 1]
  own = target.split(".")
  if written != ""
    return "" if method == written

    typed = name
    if asked.size == 1 and own.size > 1
      typed = "#{own[0]}.#{name}"
    end

    return "`#{typed}` is written `.#{written}`\n"
  end

  return "" if method == own[own.size - 1]

  "`#{name}` is called `#{target}` in Agentica\n"
end

# `; HINT` when the checker has help for this foreign name (`Hash.new`, `String.chomp`, `select`), else `; did you
# mean "NAME"?` when a public name is close, else nothing.
def suggestion(name: String) -> String
  hint = Tables.foreign_names().get(name)
  if hint.none?
    hint = Tables.foreign_kind_methods().get(name)
  end

  return "; #{hint.unwrap!}" if hint.some?

  hints = Alias.name_hints(name)
  if hints.size > 0
    pairs = hints.keys.sort.map do |key: String| "#{key}: #{hints[key]}" end
    return "; " + pairs.join("; ")
  end

  case Suggest.closest_among(name, CALLABLE_NAMES, [])
    some(found) -> "; did you mean \"#{RubyForm.shown(found)}\"?"
    none -> ""
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
    if dot.none?
      bare = bare.push(name)
    elsif spaces.size == 0 or spaces[spaces.size - 1] != name.slice(0, dot.unwrap!)
      spaces = spaces.push(name.slice(0, dot.unwrap!))
    end
  end

  [
    "Builtins: agentica help NAME prints one signature (NAME is Namespace.function, or a bare function).",
    "  namespaces: #{spaces.join(" ")}",
    "  bare functions: #{bare.join(" ")}",
    [
      "  std modules written in Agentica (import \"std/http\", \"std/queue\", \"std/binary\", \"std/toml\", ",
      "\"std/bdd\") are not in this catalog: agentica help std/MODULE lists one.",
    ].join(""),
  ].join("\n")
end
