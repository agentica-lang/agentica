## The answers of the semantic queries (docs/future/39-semantic-cli.md, 39.5) as plain data: structs of Strings, Ints,
## Bools and lists, with no enum. They are the shapes of the `--json` forms, so the command line prints exactly what
## `std/analysis` returns (the printers in query/ take these structs). An absent value is the empty text, or an empty
## list for a value that is a struct; the JSON form writes `null` for the empty text of `doc`, `alias` and `default`.
## Open sets, such as a `kind`, are Strings: a client accepts a value it does not know. Every answer has a `version`; a
## field may be added within a version, and one that changes meaning gets a new version.

import Diagnostics from "../diagnostics/diagnostic_model"

## The place a question asked about.
export struct Place
  file: String
  line: Int
  column: Int
end

## One parameter of a function: its name, its type as written and the source text of its default value ("" for none).
export struct Parameter
  name: String
  type: String
  default: String
end

## One field of a struct, with its doc ("" for none) and the range of its name.
export struct Field
  name: String
  name_range: Diagnostics.Region
  type: String
  doc: String
end

## One variant of an enum, with the types of its payload as written, its doc ("" for none) and the range of its name.
export struct Variant
  name: String
  name_range: Diagnostics.Region
  payload: List[String]
  doc: String
end

## One top-level declaration. `kind` is "function", "struct", "enum", "alias" or "constant"; `range` is the whole
## declaration, `export` included, and `name_range` the name alone. `doc` is the whole text of the `##` block ("" for
## none) and `summary` its first paragraph on one line. A function has `parameters` and `result`, a struct its `fields`
## and an enum its `variants`; the other lists are empty.
export struct Item
  kind: String
  name: String
  name_range: Diagnostics.Region
  exported: Bool
  signature: String
  summary: String
  doc: String
  range: Diagnostics.Region
  parameters: List[Parameter]
  result: String
  fields: List[Field]
  variants: List[Variant]
end

## One name of an import list: `name` in the module, `local` in the file.
export struct ImportName
  name: String
  local: String
  range: Diagnostics.Region
end

## One import. `alias` is "" for an import with a list of names, and `names` is empty for one with an alias.
export struct Import
  path: String
  alias: String
  names: List[ImportName]
  range: Diagnostics.Region
end

## What a file declares: its doc ("" for none), its imports and its other declarations, private ones too, in source
## order. Every range is in `file`.
export struct Outline
  version: Int
  file: String
  doc: String
  imports: List[Import]
  items: List[Item]
end

## The declaration of what an expression names, or the binding of a local. `kind` is `function`, `struct`, `enum`,
## `variant`, `field` or `constant`; `parameter`, `local`, `loop` or `pattern` for a local. `range` is the whole
## declaration and `name_range` its name, in `file`. `signature` is the one line `agentica doc` gives it, and `doc` the
## whole `##` text ("" for none).
export struct Definition
  kind: String
  name: String
  file: String
  range: Diagnostics.Region
  name_range: Diagnostics.Region
  signature: String
  doc: String
end

## What a position is on. `kind` is `builtin` for the name of a builtin, `name` for another name and `expression`
## otherwise; `range` is the whole expression, in `position.file`; `text` is its source text and `type` its type as the
## file writes it. `definition` holds the declaration of what the expression names, and is empty when it names none.
## `help` is the object of `agentica help NAME --json` for a builtin (JSON null otherwise), and `signatures` holds the
## signature of each form of that builtin.
export struct TypeAt
  version: Int
  position: Place
  kind: String
  text: String
  type: String
  range: Diagnostics.Region
  definition: List[Definition]
  help: Json
  signatures: List[String]
end

## The answer of `check`: `passed` is true when the program has no problem (`ok` is a reserved name, so a field cannot
## have it). The stages stop at the first problem, so `diagnostics` holds at most one.
export struct Checked
  version: Int
  file: String
  passed: Bool
  diagnostics: List[Diagnostics.Diagnostic]
end
