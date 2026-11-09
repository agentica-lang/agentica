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

## One field of a struct, with the source text of its default value ("" for none), its doc ("" for none) and the range
## of its name.
export struct Field
  name: String
  name_range: Diagnostics.Region
  type: String
  default: String
  doc: String
end

## One variant of an enum, with the types of its payload as written, its doc ("" for none) and the range of its name.
export struct Variant
  name: String
  name_range: Diagnostics.Region
  payload: List[String]
  doc: String
end

## One top-level declaration. `kind` is "function", "struct", "enum", "alias", "resource" or "constant"; `range` is
## the whole declaration, `export` included, and `name_range` the name alone. `doc` is the whole text of the `##` block
## ("" for none) and `summary` its first paragraph on one line. A function has `parameters` and `result`, a struct its
## `fields` and an enum its `variants`; the other lists are empty.
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

## What a position is on. `kind` is `builtin` for the name of a builtin, `type` for the name of a type in an annotation
## or a type argument, `name` for another name and `expression` otherwise; `range` is the whole expression, in
## `position.file`; `text` is its source text and `type` its type as the file writes it (the written name for a
## `type`). `definition` holds the declaration of what the expression names, and is empty when it names none.
## `help` is the object of `agentica help NAME --json` for a builtin (JSON null otherwise), and `signatures` holds the
## signature of each form of that builtin. `partial` is true for an answer from a program that does not check
## (docs/future/39-semantic-cli.md, 39.6): `diagnostics` are its problems, and `type` is "" when the answer is known
## from the link alone, such as a name in a function that did not check. A complete answer has `partial` false and no
## diagnostics.
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
  partial: Bool
  diagnostics: List[Diagnostics.Diagnostic]
end

## The answer of `check`: `passed` is true when the program has no problem (`ok` is a reserved name, so a field cannot
## have it). The stages stop at the first problem, so `diagnostics` holds at most one.
export struct Checked
  version: Int
  file: String
  passed: Bool
  diagnostics: List[Diagnostics.Diagnostic]
end

## One declaration that `symbol` found. `kind` is `function`, `struct`, `enum`, `alias`, `constant`, `field`,
## `variant` or `builtin`; `name` is the name alone and `owner` the struct or enum of a field or a variant ("" for
## others). `module` is the file of the declaration, and `range` and `name_range` are in it; a builtin has no place, so
## its `module` is "". `exported` is the flag of the declaration, or of the struct or enum of a member, and `doc` the
## whole `##` text ("" for none). A field has its `type`, a variant its `payload`; a builtin has `help` (the object of
## `agentica help NAME --json`, JSON null for the others) and the signature of each of its forms in `signatures`.
export struct Symbol
  kind: String
  name: String
  owner: String
  module: String
  exported: Bool
  signature: String
  doc: String
  range: Diagnostics.Region
  name_range: Diagnostics.Region
  type: String
  payload: List[String]
  help: Json
  signatures: List[String]
end

## A file of a `symbol` query that was left out, with the first problem it hit.
export struct Skipped
  file: String
  diagnostic: Diagnostics.Diagnostic
end

## The answer of `symbol` for `query`: the matches, in the order the modules were linked and then in source order (the
## builtin last), and the files left out.
export struct Symbols
  version: Int
  query: String
  matches: List[Symbol]
  skipped: List[Skipped]
end

## One use of a declaration: its `kind` (`call`, `value`, `type`, `construct`, `read`, `pattern` or `binding`), the
## `function` it is in ("" at the top level), and the `range` of the name in `file`.
export struct Reference
  kind: String
  function: String
  file: String
  range: Diagnostics.Region
end

## The answer of `refs` for `query` (`FILE:LINE:COL` or the name, as asked). `definition` is the declaration as
## `symbol` lists it (a `Symbol`; its kind is `parameter`, `local`, `loop` or `pattern` for a local) and is empty for a
## builtin, which `builtin` names (`File.read`; "" for anything else). `references` do not include the definition; they
## are in the order of the linked files and, within one file, of the text. `skipped` holds the files left out, as for
## `symbol`. `partial` and `diagnostics` are as for `TypeAt`: the answer of a program that does not check.
export struct Refs
  version: Int
  query: String
  definition: List[Symbol]
  builtin: String
  references: List[Reference]
  skipped: List[Skipped]
  partial: Bool
  diagnostics: List[Diagnostics.Diagnostic]
end

## One parameter of a function of a native module: its name and its canonical type, the text the module's function
## table has ("List[Float]", aliases expanded, user types by their bare names).
export struct NativeParameter
  name: String
  type: String
end

## One function of an `extern module` block, named as the block writes it (`empty?` included). `mode` is `short` for a
## `def` and `dirty` for a `compute def`. `signature` is the canonical text of the module's function table,
## "(List[Float]) -> Optional[Summary]". `types_in` and `types_out` are the bare names of the structs, enums and
## resources that the parameters and that the result reach, through the fields and payloads too, each once; the
## block's `types` and `resources` describe them. Each list is in the order of its own walk, which is not a
## subsequence of the block's `types` order: for a parameter `A{b: B}`, `B{c: C}` and a result `C` the block lists
## A, C, B but `types_in` is A, B, C, so do not merge them by position. A type in `types_out` only is made by the
## module and never read, and one in `types_in` only is read and never made. `doc` is the whole `##` text ("" for
## none), `range` the whole declaration, `export` included, and `name_range` the name alone.
export struct NativeFunction
  name: String
  name_range: Diagnostics.Region
  mode: String
  exported: Bool
  doc: String
  range: Diagnostics.Region
  parameters: List[NativeParameter]
  result: String
  signature: String
  types_in: List[String]
  types_out: List[String]
end

## One `resource Name` line of an `extern module` block, with the same fields as a function.
export struct NativeResource
  name: String
  name_range: Diagnostics.Region
  exported: Bool
  doc: String
  range: Diagnostics.Region
end

## One field of a struct that crosses, or one variant of an enum: its name and its canonical types (a field has one, a
## variant its payload).
export struct NativeMember
  name: String
  types: List[String]
end

## A struct or enum of the program that crosses to the module. `kind` is `struct` or `enum`, `name` its bare name,
## `members` its fields or variants in declared order, and `shape` the exact text that the loader compares with the
## module's type table ("count: Int, mean: Float", "Empty | Number(Float) | Text(String)"), the one the lowering writes
## after `=` in the `{S<index>=...}` or `{E<index>=...}` of a signature. (The index is the place of the type in the
## program's tables, which a generator does not need.)
export struct NativeType
  kind: String
  name: String
  members: List[NativeMember]
  shape: String
end

## One `extern module "NAME"` block. `library` is the NAME as written, and `range` runs from the first to the last
## declaration of the block, without its `extern module` line and its `end` (the syntax tree keeps no place for the
## NAME). Blocks of one NAME are one block, so its range may cover another block's declarations and two ranges may
## overlap. `types` are the structs and enums that cross in its functions, each once, in the order the first function
## that reaches them meets them. `api_major` and `api_minor` are the least version of the C API (AN_API_MAJOR and
## AN_API_MINOR of vm/agentica_native.h) that has what the block needs: 1.0 for functions of scalars and collections,
## 1.1 when a struct or enum crosses, 1.2 for a resource.
export struct NativeBlock
  library: String
  range: Diagnostics.Region
  api_major: Int
  api_minor: Int
  functions: List[NativeFunction]
  resources: List[NativeResource]
  types: List[NativeType]
end

## The answer of `native_modules`: the `extern module` blocks of a file, in source order.
export struct NativeModules
  version: Int
  file: String
  blocks: List[NativeBlock]
end

## A resolved type of `bodies`. `kind` is `builtin` (`name` is Int, Bytes, List, Result, Fn, ...), `struct`, `enum`
## or `opaque` (`name` is the linked name, `@N::Name` for one of another file), `var` (a type parameter, `name` as
## written) or `none` (a node that has no value, such as a statement). `args` are the type arguments in order; an `Fn`
## has its parameters, then its result.
export struct TypeShape
  kind: String
  name: String
  args: List[TypeShape]
end

## One node of the typed tree of a body. `kind` says what it is, and `children` are its parts in source order:
## - `int`, `float`, `string`, `bool`, `nil`: a literal; `text` is its value (the digits, the text of a string,
##   `true`).
## - `local`: a read of a parameter or local, `text` its name.
## - `let`: `text = child`; `new` is true when it makes a new local, false when it changes a visible one.
## - `call`: `target` is the function or builtin the checker resolved (`window`, `@2::helper`, `Int.shift_left`,
##   `Bytes.length` for `data.size`, `Bytes.at` for `data[i]`, `ok`, `some`); the children are the arguments, the
##   receiver of a method first.
## - `index`: `target[index]` on a List or Map; the children are the target and the index.
## - `op`: a binary operator, `text` its token (`plus`, `minus`, `less`, `equal`, `not-equal`, ...); the two children
##   carry their own types. `and`, `or`, `not` and `neg` (unary minus) are their own kinds.
## - `try`: its operand. `return`: its value, if any.
## - `interpolation`: `string` nodes and the typed expressions between them.
## - `if`: one `branch` (the condition, then a `block`) per `if` and `elsif`, then a `block` for `else` when written.
## - `case`: the value, then one `arm` each: its pattern, a `guard` (holding the condition) when written, then a
##   `block`.
## - Patterns: `wildcard`; `literal` (`text` as for a literal); `variant`, whose `target` is `Enum.Variant` (the linked
##   enum name), `ok`, `error`, `some` or `none`, and whose children are its slots: `bind` (`text` the name), `skip`
##   (`_`) or a nested pattern. A pattern's type is the type it matches.
## - `block`: the statements of a body.
## - `other`: a node that this version does not describe yet; `text` is its syntax (`while`, `list`, ...), and it has
##   no children.
## `range` is the place of the node; a `string` part of an interpolation has the range of the interpolation.
export struct Node
  kind: String
  type: TypeShape
  range: Diagnostics.Region
  text: String
  target: String
  new: Bool
  children: List[Node]
end

## One parameter of a function of `bodies`, with its resolved type.
export struct BodyParam
  name: String
  type: TypeShape
  range: Diagnostics.Region
end

## One function of `bodies`: `name` as written, `linked` the name a `call` node targets, `generics` its type
## parameters, the resolved types of its parameters and result, and its body as a list of statement nodes.
export struct Body
  name: String
  linked: String
  exported: Bool
  range: Diagnostics.Region
  name_range: Diagnostics.Region
  generics: List[String]
  params: List[BodyParam]
  result: TypeShape
  body: List[Node]
end

## The answer of `bodies` (experimental): every function of a file with a body, private ones too, in source order.
export struct Bodies
  version: Int
  file: String
  functions: List[Body]
end
