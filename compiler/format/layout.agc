## The layout of the formatter: the document of a parsed file, with its comments
## where the attachment put them (47.4).
##
## The tree has no node for the text of a literal, so literals, interpolated strings, patterns and guards are copied
## from the source; a heredoc keeps its body byte for byte after the line of its opener. An `extern` block is copied
## whole, because the tree keeps only the Agentica types of its C types. Everything else is printed from the tree:
## the printer chooses the grouping parentheses from the precedence (47.5 rule 4), and a broken expression that is
## not already inside brackets gets its own.
##
## Between two items of a body (a declaration, a statement, a field, a variant, a `case` arm or a comment) a blank
## line stays when the source had one right before the second item, at most one. One is added after a simple statement
## that takes several lines (`sequence`). A pipe chain of two or more `|>` that is the whole value of a statement
## always breaks, one stage per line.

import Ast from "../syntax/ast"
import Source from "../syntax/source"
import Tokens from "../syntax/token"
import Comments from "comments"
import Docs from "doc"

# The binary operators by token kind, with the level of the parser (compiler/syntax/parser.agc LEVELS). A range is
# looser than all of them and does not chain.
LEVELS: Map[String, Int] = {
  "or": 1,
  "and": 2,
  "equal": 3,
  "not-equal": 3,
  "less": 4,
  "less-equal": 4,
  "greater": 4,
  "greater-equal": 4,
  "pipe-forward": 5,
  "plus": 6,
  "minus": 6,
  "multiply": 7,
  "divide": 7,
  "modulo": 7,
}
# The level of `|>`, of `try`, `-` and `not`, and of a postfix or primary expression.
PIPE_LEVEL = 5
UNARY_LEVEL = 8
POSTFIX_LEVEL = 9
# A width no line reaches: a doc laid out in it breaks only where it must.
UNLIMITED = 1000000
EXPORT = "export "

## What the layout reads besides the tree: the source lines, the tokens that are not line breaks with their starts,
## the comments of each node by its key (`Comments.key_of`), the body of each heredoc by the offset of its opener, and
## the `extern` blocks.
export struct Context
  lines: List[String]
  tokens: List[Tokens.Token]
  starts: List[Int]
  leading: Map[String, List[Tokens.Comment]]
  trailing: Map[String, List[Tokens.Comment]]
  dangling: Map[String, List[Comments.Attached]]
  heredocs: Map[Int, List[String]]
  externs: List[Extern]
  # The lines that hold a comment, so that an `if` with a comment is never turned into a guard.
  noted: Set[Int]
  # The width of a line, which decides before the layout whether a one-line def stays one (one_line_form).
  width: Int
  # The type aliases of the file whose target is Void (void_aliases): a def with such a result keeps its last `return`.
  void_aliases: List[String] = []
end

## An `extern` block, copied whole: its first and last lines and offsets, and the comments that the attachment gave
## to its declarations from outside it, before and after it.
export struct Extern
  first: Int
  last: Int
  start: Int
  stop: Int
  before: List[Tokens.Comment]
  after: List[Tokens.Comment]
end

# One item of a body: its first and last source lines and its document, whether it is a simple statement whose
# document is measured (it owes an empty line after it when it took several lines), and whether it is a comment that
# closes its body (it does not take the empty line that is owed, as no item follows to be told apart from it).
struct Item
  first: Int
  last: Int
  doc: Docs.Doc
  spread: Bool
  closing: Bool
  # A one-line def of the source, and one that the layout writes with a body: next to another one-line def, which the
  # source may have on the next line, it needs an empty line (sequence).
  one_line: Bool = false
  gap: Bool = false
end

# The comments of a node before it and after it, as documents to put around it.
struct Around
  before: List[Docs.Doc]
  after: List[Docs.Doc]
end

# A link of a method chain: its document (from the `.` or `[`) without its trailing `do` block, which `block` holds,
# whether it is a call, and whether a chain may break before it.
struct Link
  doc: Docs.Doc
  block: List[Docs.Doc]
  call: Bool
  breaks: Bool
end

## Builds the context of a file from its text, its tokens, its comments and their attachment.
export def context(text: String, tokens: List[Tokens.Token], attachment: Comments.Attachment, width: Int) -> Context
  lines = text.split("\n")
  kept = tokens.select do |token: Tokens.Token| token.kind != "NL" and token.kind != "EOF" end
  starts = kept.map do |token: Tokens.Token| token.span.start.offset end
  externs = extern_blocks(lines, kept)
  leading: Map[String, List[Tokens.Comment]] = {}
  trailing: Map[String, List[Tokens.Comment]] = {}
  dangling: Map[String, List[Comments.Attached]] = {}
  for placed in attachment.comments
    node = attachment.nodes[placed.node]
    offset = placed.comment.span.start.offset
    inside = extern_at(externs, node.span.start.offset)
    if extern_at(externs, offset) >= 0
      # Copied with its block.
      inside = inside
    elsif inside >= 0
      block = externs[inside]
      if offset < block.start
        externs = externs.set(inside, block.with(before: block.before.push(placed.comment)))
      else
        externs = externs.set(inside, block.with(after: block.after.push(placed.comment)))
      end
    else
      case placed.role
        Comments.Role.Leading -> leading = leading.put(node.key, leading.get(node.key, []).push(placed.comment))
        Comments.Role.Trailing -> trailing = trailing.put(node.key, trailing.get(node.key, []).push(placed.comment))
        Comments.Role.Dangling -> dangling = dangling.put(node.key, dangling.get(node.key, []).push(placed))
      end
    end
  end

  Context(
    lines: lines,
    tokens: kept,
    starts: starts,
    leading: leading,
    trailing: trailing,
    dangling: dangling,
    heredocs: heredoc_bodies(lines, kept),
    externs: externs,
    noted: Set.new(attachment.comments.map do |placed: Comments.Attached| placed.comment.span.start.line end),
    width: width,
  )
end

## The document of a file.
export def program_doc(c: Context, program: Ast.Program) -> Docs.Doc
  c = c.with(void_aliases: void_aliases(program.declarations))
  items: List[Item] = []
  if program.module_doc.some? and c.tokens.size > 0 and c.tokens[0].kind == "DOC"
    token = c.tokens[0]
    key = Comments.key_of("ModuleDoc", token.span)
    first = token.span.start.line
    # The module doc is an item of its own: its lines without the break after the last one.
    lines = doc_lines(c, first)
    items = items.concat(node_items(c, key, first, doc_last(c, first), Docs.Doc.Concat(lines.take(lines.size - 1))))
  end

  printed: Set[Int] = Set.new([])
  for decl in program.declarations
    start = decl_span(decl).start.offset
    block = extern_at(c.externs, start)
    if block < 0
      items = items.concat(decl_items(c, decl))
    elsif not printed.include?(block)
      printed = printed.add(block)
      items = items.concat(extern_items(c, c.externs[block]))
    end
  end

  for placed in c.dangling.get(Comments.key_of("Program", program.span), [])
    items = items.push(comment_item(placed.comment))
  end

  sequence(c, items)
end

# ---- Items, blank lines and comments ----

# The items joined by line breaks, with an empty line where the source had a blank line right before an item, and
# after a simple statement that took several lines when another item comes next, a comment included: a comment
# alone on its line after a blank line belongs to the item below it, so the formatted text must not read differently
# when it is formatted again. The statement owes that line, and the printer pays it only when the statement did take
# several lines.
def sequence(c: Context, items: List[Item]) -> Docs.Doc
  parts: List[Docs.Doc] = []
  owed = false
  at = 0
  while at < items.size
    item = items[at]
    if at > 0
      before = items[at - 1]
      if blank_before?(c, item.first, before.last) or gap_between?(before, item)
        parts = parts.concat([Docs.Doc.HardLine, Docs.Doc.HardLine])
      elsif owed and not item.closing
        parts = parts.push(Docs.Doc.GapLine)
      else
        parts = parts.push(Docs.Doc.HardLine)
      end
    end

    owed = item.spread

    parts = parts.push(item.doc)
    at += 1
  end

  Docs.Doc.Concat(parts)
end

# Whether two declarations that follow each other need an empty line that the source may lack: both are one-line defs
# of the source, which the parser lets follow each other, and the layout writes one of them with a body.
def gap_between?(before: Item, item: Item) -> Bool = item.one_line and before.one_line and (item.gap or before.gap)

# Whether the line right before `first` is blank and comes after `last`.
def blank_before?(c: Context, first: Int, last: Int) -> Bool
  above = first - 1
  above > last and above >= 1 and above <= c.lines.size and c.lines[above - 1].strip == ""
end

# The items of a node: its leading comments, the node with its comments after code, and the comments alone on their
# lines after it.
def node_items(c: Context, key: String, first: Int, last: Int, doc: Docs.Doc) -> List[Item]
  node_items_of(c, key, first, last, doc, false)
end

# `node_items`, where `spread` says that `doc` is a measured simple statement.
def node_items_of(c: Context, key: String, first: Int, last: Int, doc: Docs.Doc, spread: Bool) -> List[Item]
  items: List[Item] = c.leading.get(key, []).map do |comment: Tokens.Comment| comment_item(comment) end
  suffixes: List[Docs.Doc] = []
  below: List[Item] = []
  for comment in c.trailing.get(key, [])
    if comment.own_line
      below = below.push(closing_item(comment))
    else
      suffixes = suffixes.push(Docs.Doc.LineSuffix(" " + comment.text))
    end
  end

  shown = Docs.Doc.Concat([doc].concat(suffixes))
  items = items.push(Item(first: first, last: last, doc: shown, spread: spread, closing: false))
  items.concat(below)
end

def comment_item(comment: Tokens.Comment) -> Item
  line = comment.span.start.line
  Item(first: line, last: line, doc: Docs.Doc.Comment(comment.text), spread: false, closing: false)
end

# A comment alone at the end of its body.
def closing_item(comment: Tokens.Comment) -> Item = comment_item(comment).with(closing: true)

# The comments of a node inside an expression: the leading ones on their own lines before it, a comment after code at
# the end of its line, and a comment alone on its line after it on the next line.
def around(c: Context, key: String) -> Around
  before: List[Docs.Doc] = []
  for comment in c.leading.get(key, [])
    before = before.concat([Docs.Doc.Comment(comment.text), Docs.Doc.HardLine])
  end

  after: List[Docs.Doc] = []
  for comment in c.trailing.get(key, [])
    if comment.own_line
      after = after.concat([Docs.Doc.Below(comment.text), Docs.Doc.BreakParent])
    else
      after = after.concat([Docs.Doc.LineSuffix(" " + comment.text), Docs.Doc.BreakParent])
    end
  end

  Around(before: before, after: after)
end

def commented(c: Context, key: String, doc: Docs.Doc) -> Docs.Doc
  found = around(c, key)
  return doc if found.before.size == 0 and found.after.size == 0

  Docs.Doc.Concat(found.before.push(doc).concat(found.after))
end

# The dangling comments of a node, each on its own line, as the items of an empty body.
def dangling_items(c: Context, key: String) -> List[Item]
  c.dangling.get(key, []).map do |placed: Comments.Attached| closing_item(placed.comment) end
end

# A body two spaces deeper, from the line after its header; nothing for an empty body.
def body(c: Context, items: List[Item]) -> Docs.Doc
  return Docs.Doc.Concat([]) if items.size == 0

  Docs.Doc.Indent([Docs.Doc.HardLine, sequence(c, items)])
end

# ---- Declarations ----

def decl_items(c: Context, decl: Ast.Decl) -> List[Item] = decl_items_at(c, decl, 0)

# The items of a declaration that starts `column` columns in: 0 at the top level, 2 inside a module block.
def decl_items_at(c: Context, decl: Ast.Decl, column: Int) -> List[Item]
  span = decl_span(decl)
  key = Comments.key_of(Comments.decl_kind(decl), span)
  first = span.start.line
  parts: List[Docs.Doc] = []
  if has_doc?(decl)
    first = doc_first(c, span.start.offset)
    parts = doc_lines(c, first)
  end

  form = one_line_form(c, decl, column)
  doc = Docs.Doc.Concat(parts.push(decl_doc(c, decl, form)))
  items = node_items(c, key, first, last_line(c, span), doc)
  at = c.leading.get(key, []).size
  one_line = one_line_def?(decl)
  items.set(at, items[at].with(one_line: one_line, gap: one_line and form.none?))
end

# A def with a body that can be a one-line def: it returns a value (not Void, so never `main`), its body is one
# `return value`, and no comment sits from its `def` line to its `end` line, where the one line would lose it. Whether
# the value fits on the line is read from the layout (one_line_form), not from the source, so a value that the source
# spreads over lines and the layout joins is a one-line def already on the first run.
def one_line_body?(c: Context, node: Ast.FunctionDecl) -> Bool
  return false if node.native.some? or node.body.size != 1 or not written?(node.result.span)

  return false if void_result?(c, node.result)

  case node.body[0]
    Ast.Stmt.Return(stmt) -> return false if stmt.value.none?
    _ -> return false
  end

  last = last_line(c, node.span)
  not (node.span.start.line..last).to_a.any? do |line: Int| c.noted.include?(line) end
end

# A one-line def of the source, exported or not.
def one_line_def?(decl: Ast.Decl) -> Bool
  case decl
    Ast.Decl.Export(node) -> one_line_def?(node.declaration)
    Ast.Decl.Function(node) -> node.expression
    _ -> false
  end
end

# The one line of a def that starts `column` columns in, when it is written as one: a one-line def, or a def whose
# body is one `return value` (one_line_body?), laid out with no width limit is one line, and that line fits.
# Otherwise, or for any other declaration, none: the def is written with a body, so the output always parses and
# formatting again changes nothing. The choice is made before the layout, since a one-line def written with a body
# needs an empty line next to another one-line def (sequence); a def with a body written as one line keeps the empty
# lines around it.
def one_line_form(c: Context, decl: Ast.Decl, column: Int) -> Optional[Docs.Doc]
  case decl
    Ast.Decl.Export(node) -> one_line_form(c, node.declaration, column + EXPORT.length)
    Ast.Decl.Function(node) ->
      return none if not node.expression and not one_line_body?(c, node)

      doc = one_line_doc(c, node)
      line = Docs.render(doc, UNLIMITED).strip
      return none if line.include?("\n") or column + line.length > c.width

      some(doc)
    _ -> none
  end
end

def has_doc?(decl: Ast.Decl) -> Bool
  case decl
    Ast.Decl.Export(node) -> node.doc.some?
    Ast.Decl.Function(node) -> node.doc.some?
    Ast.Decl.Struct(node) -> node.doc.some?
    Ast.Decl.Enum(node) -> node.doc.some?
    Ast.Decl.TypeAlias(node) -> node.doc.some?
    Ast.Decl.Constant(node) -> node.doc.some?
    Ast.Decl.Module(node) -> node.doc.some?
    _ -> false
  end
end

# A declaration without its doc, which `decl_items` prints before it. `form` is the one line of a one-line def that
# stays one (one_line_form).
def decl_doc(c: Context, decl: Ast.Decl, form: Optional[Docs.Doc]) -> Docs.Doc
  case decl
    Ast.Decl.Import(node) -> import_doc(c, node)
    Ast.Decl.Reexport(node) -> text("export #{node.alias}.#{node.name}")
    Ast.Decl.Export(node) -> Docs.Doc.Concat([text(EXPORT), decl_doc(c, node.declaration, form)])
    Ast.Decl.Function(node) ->
      case form
        some(line) -> line
        none -> function_doc(c, node)
      end

    Ast.Decl.Struct(node) -> struct_doc(c, node)
    Ast.Decl.Enum(node) -> enum_doc(c, node)
    Ast.Decl.TypeAlias(node) ->
      Docs.Doc.Concat([text("type #{node.name}#{type_parameters(node.type_parameters)} = "), type_doc(c, node.target)])
    Ast.Decl.Resource(node) -> text(source(c, node.span))
    Ast.Decl.Constant(node) -> constant_doc(c, node)
    Ast.Decl.Module(node) -> module_block_doc(c, node)
  end
end

# A module block: its declarations two spaces in, laid out as those of a file.
def module_block_doc(c: Context, node: Ast.ModuleDecl) -> Docs.Doc
  items: List[Item] = []
  for decl in node.declarations
    items = items.concat(decl_items_at(c, decl, 2))
  end

  items = items.concat(dangling_items(c, Comments.key_of("ModuleDecl", node.span)))
  Docs.Doc.Concat([text("module #{node.name}"), body(c, items), Docs.Doc.HardLine, text("end")])
end

def import_doc(c: Context, node: Ast.ImportDecl) -> Docs.Doc
  path = import_path(c, node)
  case node.alias
    some(alias) -> text("import #{alias} from #{path}")
    none ->
      names = node.names.map do |entry: Ast.ImportName| import_name(entry) end
      packed = shared_line?(node.names.map do |entry: Ast.ImportName| entry.span.start.line end)
      Docs.Doc.Concat([packed_list(text("import {"), names, text("}"), [], packed), text(" from #{path}")])
  end
end

def import_name(entry: Ast.ImportName) -> Docs.Doc
  return text(entry.name) if entry.local == entry.name

  text("#{entry.name} as #{entry.local}")
end

# The path of an import as written: its last string token.
def import_path(c: Context, node: Ast.ImportDecl) -> String
  at = token_index(c, node.span.start.offset)
  found = ""
  while at < c.tokens.size and c.tokens[at].span.start.offset < node.span.stop.offset
    if c.tokens[at].kind == "string"
      found = source(c, c.tokens[at].span)
    end

    at += 1
  end

  found
end

# A def with its body: also a one-line def that does not stay one (one_line_form).
def function_doc(c: Context, node: Ast.FunctionDecl) -> Docs.Doc
  key = Comments.key_of("FunctionDecl", node.span)
  stmts = node.body
  if not void_result?(c, node.result)
    stmts = tail_values(stmts)
  end

  items = statement_items(c, stmts).concat(dangling_items(c, key))
  Docs.Doc.Concat([Docs.Doc.Group(signature_doc(c, node)), body(c, items), Docs.Doc.HardLine, text("end")])
end

# `def name(params) -> Type`.
def signature_doc(c: Context, node: Ast.FunctionDecl) -> List[Docs.Doc]
  params = node.params.map do |param: Ast.Param| param_doc(c, param) end
  head: List[Docs.Doc] = [
    text("def #{node.name}#{type_parameters(node.type_parameters)}"),
    listed(text("("), params, text(")"), []),
  ]

  return head if not written?(node.result.span)

  head.concat([text(" -> "), type_doc(c, node.result)])
end

# `def name(params) -> Type = value`, for a one-line def.
def one_line_doc(c: Context, node: Ast.FunctionDecl) -> Docs.Doc
  Docs.Doc.Concat([Docs.Doc.Group(signature_doc(c, node)), text(" = "), expression_value_doc(c, node.body[0])])
end

# The value after `=` of a one-line def (`def name() -> Type = value`), laid out as the value of its `return` in a
# body, with the comments of that `return`.
def expression_value_doc(c: Context, stmt: Ast.Stmt) -> Docs.Doc
  key = Comments.key_of(Comments.stmt_kind(stmt), Ast.stmt_span(stmt))
  case stmt
    Ast.Stmt.Return(node) ->
      case node.value
        some(value) -> commented(c, key, value_doc(c, value, true))
        none -> statement_doc(c, stmt, true)
      end

    _ -> statement_doc(c, stmt, true)
  end
end

def param_doc(c: Context, param: Ast.Param) -> Docs.Doc
  parts = [text("#{param.name}: "), type_doc(c, param.type)].concat(default_doc(c, param.default))
  commented(c, Comments.key_of("Param", param.span), Docs.Doc.Concat(parts))
end

def default_doc(c: Context, value: Optional[Ast.Expr]) -> List[Docs.Doc]
  case value
    some(expr) -> [text(" = "), expr_doc(c, expr, false)]
    none -> []
  end
end

def struct_doc(c: Context, node: Ast.StructDecl) -> Docs.Doc
  key = Comments.key_of("StructDecl", node.span)
  items: List[Item] = []
  for field in node.fields
    items = items.concat(field_items(c, field))
  end

  items = items.concat(dangling_items(c, key))
  head = text("struct #{node.name}#{type_parameters(node.type_parameters)}")
  Docs.Doc.Concat([head, body(c, items), Docs.Doc.HardLine, text("end")])
end

def field_items(c: Context, field: Ast.FieldDecl) -> List[Item]
  first = field.span.start.line
  parts: List[Docs.Doc] = []
  if field.doc.some?
    first = doc_first(c, field.span.start.offset)
    parts = doc_lines(c, first)
  end

  parts = parts.concat([text("#{field.name}: "), type_doc(c, field.type)]).concat(default_doc(c, field.default))
  key = Comments.key_of("FieldDecl", field.span)
  node_items(c, key, first, last_line(c, field.span), Docs.Doc.Concat(parts))
end

def enum_doc(c: Context, node: Ast.EnumDecl) -> Docs.Doc
  key = Comments.key_of("EnumDecl", node.span)
  items: List[Item] = []
  for variant in node.variants
    items = items.concat(variant_items(c, variant))
  end

  items = items.concat(dangling_items(c, key))
  head = text("enum #{node.name}#{type_parameters(node.type_parameters)}")
  Docs.Doc.Concat([head, body(c, items), Docs.Doc.HardLine, text("end")])
end

def variant_items(c: Context, variant: Ast.EnumVariant) -> List[Item]
  first = variant.span.start.line
  parts: List[Docs.Doc] = []
  if variant.doc.some?
    first = doc_first(c, variant.span.start.offset)
    parts = doc_lines(c, first)
  end

  parts = parts.push(text(variant.name))
  if variant.payload_types.size > 0
    # The grammar takes no trailing comma here, so the payload stays on the line of its variant.
    types = variant.payload_types.map do |type: Ast.TypeRef| type_doc(c, type) end
    parts = parts.concat([text("("), join(types, [text(", ")]), text(")")])
  end

  key = Comments.key_of("EnumVariant", variant.span)
  node_items(c, key, first, last_line(c, variant.span), Docs.Doc.Concat(parts))
end

def constant_doc(c: Context, node: Ast.ConstDecl) -> Docs.Doc
  parts: List[Docs.Doc] = []
  if node.exported
    parts = parts.push(text("export "))
  end

  parts = parts.push(text(node.name))
  case node.type
    some(type) -> parts = parts.concat([text(": "), type_doc(c, type)])
    none -> parts = parts
  end

  Docs.Doc.Concat(parts.concat([text(" = "), expr_doc(c, node.value, false)]))
end

def type_parameters(names: List[String]) -> String
  return "" if names.size == 0

  "[#{names.join(", ")}]"
end

def type_doc(c: Context, type: Ast.TypeRef) -> Docs.Doc
  doc = text(type.name)
  if type.args.size > 0
    args = type.args.map do |arg: Ast.TypeRef| type_doc(c, arg) end
    doc = Docs.Doc.Concat([doc, text("["), join(args, [text(", ")]), text("]")])
  end

  commented(c, Comments.key_of("TypeRef", type.span), doc)
end

# An `extern` block as written, with the comments before and after it.
def extern_items(c: Context, block: Extern) -> List[Item]
  items = block.before.map do |comment: Tokens.Comment| comment_item(comment) end
  lines: List[Docs.Doc] = []
  line = block.first
  while line <= block.last
    if line > block.first
      lines = lines.push(Docs.Doc.HardLine)
    end

    lines = lines.push(text(trim_end(c.lines[line - 1])))
    line += 1
  end

  # The block keeps its own indent: it starts at the left margin, as every declaration does.
  shown = Docs.Doc.Concat(lines)
  items = items.push(Item(first: block.first, last: block.last, doc: shown, spread: false, closing: false))
  suffixes: List[Item] = []
  for comment in block.after
    if comment.span.start.line == block.last
      items = items.set(
        items.size - 1,
        items[items.size - 1].with(
          doc: Docs.Doc.Concat([items[items.size - 1].doc, Docs.Doc.LineSuffix(" " + comment.text)]),
        ),
      )
    else
      suffixes = suffixes.push(comment_item(comment))
    end
  end

  items.concat(suffixes)
end

# ---- Statements ----

def statement_items(c: Context, stmts: List[Ast.Stmt]) -> List[Item]
  items: List[Item] = []
  for stmt in stmts
    span = Ast.stmt_span(stmt)
    key = Comments.key_of(Comments.stmt_kind(stmt), span)
    doc = statement_doc(c, stmt, true)
    if simple?(stmt)
      doc = Docs.Doc.Measure([doc])
    end

    lines = grouped_lines(c, stmt, span)
    items = items.concat(node_items_of(c, key, lines.start.line, lines.stop.line, doc, simple?(stmt)))
  end

  items
end

# The span of a statement from its first token to its last. The span of an implicit `return` is its value's, which
# may start after the value does (a pipe chain has the span of its last call) and leaves out the parentheses around
# it (`(` on a line of its own before a pipe chain), so both are added back: else the empty line before the value
# would be lost on the next run.
def grouped_lines(c: Context, stmt: Ast.Stmt, span: Source.Span) -> Source.Span
  tight_span = tight(c, span)
  case stmt
    Ast.Stmt.Return(node) ->
      return tight_span if not node.implicit

      case node.value
        some(value) ->
          first = value_start(value)
          if first.offset < tight_span.start.offset
            tight_span = tight_span.with(start: first)
          end

        none -> return tight_span
      end

    _ -> return tight_span
  end

  before = token_index(c, tight_span.start.offset) - 1
  after = token_index(c, tight_span.stop.offset)
  start = tight_span.start
  stop = tight_span.stop
  while before >= 0 and after < c.tokens.size and c.tokens[before].kind == "left-paren"
    break if c.tokens[after].kind != "right-paren"

    start = c.tokens[before].span.start
    stop = c.tokens[after].span.stop
    before -= 1
    after += 1
  end

  tight_span.with(start: start, stop: stop)
end

# Where an expression starts in the source: a piped call starts at the value piped into it, and a node whose span
# starts at its first operand starts where that operand does.
def value_start(expr: Ast.Expr) -> Source.Position
  own = Ast.expr_span(expr).start
  inner = own
  case expr
    Ast.Expr.Call(call) ->
      if call.piped and call.args.size > 0
        inner = value_start(call.args[0])
      end

    Ast.Expr.Try(node) -> inner = value_start(node.operand)
    Ast.Expr.Binary(node) -> inner = value_start(node.left)
    Ast.Expr.MethodCall(node) -> inner = value_start(node.target)
    Ast.Expr.FieldAccess(node) -> inner = value_start(node.target)
    Ast.Expr.Index(node) -> inner = value_start(node.target)
    _ -> inner = own
  end

  return inner if inner.offset < own.offset

  own
end

# A statement. `forced` says that it is an item of a body, where a pipe chain of two or more `|>` that is the whole
# value of the statement always breaks; the body of a one-line `do` block or of a `case` arm keeps the fit rule.
def statement_doc(c: Context, stmt: Ast.Stmt, forced: Bool) -> Docs.Doc
  case stmt
    Ast.Stmt.Binding(node) -> binding_doc(c, node, forced)
    Ast.Stmt.Return(node) ->
      case node.value
        some(value) ->
          return value_doc(c, value, forced) if node.implicit and not try?(value)

          Docs.Doc.Concat([text("return "), value_doc(c, value, forced)])
        none -> text("return")
      end

    Ast.Stmt.Expression(node) -> value_doc(c, node.value, forced)
    Ast.Stmt.If(node) -> if_doc(c, node)
    Ast.Stmt.While(node) ->
      key = Comments.key_of("WhileStmt", node.span)
      items = statement_items(c, node.body).concat(dangling_items(c, key))
      head = Docs.Doc.Concat([
        text("while "),
        expr_doc(c, node.condition, false),
        text(optional_do(c, node.condition)),
      ])

      Docs.Doc.Concat([head, body(c, items), Docs.Doc.HardLine, text("end")])
    Ast.Stmt.For(node) ->
      key = Comments.key_of("ForStmt", node.span)
      items = statement_items(c, node.body).concat(dangling_items(c, key))
      iterable = expr_doc(c, node.iterable, false)
      head = Docs.Doc.Concat([text("for #{node.variable} in "), iterable, text(optional_do(c, node.iterable))])
      Docs.Doc.Concat([head, body(c, items), Docs.Doc.HardLine, text("end")])
    Ast.Stmt.Control(node) -> text(node.kind)
    Ast.Stmt.Case(node) -> case_doc(c, node)
  end
end

# `name = value`, `name: Type = value`, or a compound assignment such as `name += value`, which the parser keeps as
# `name = name + value`: the token after the name tells them apart.
def binding_doc(c: Context, node: Ast.Binding, forced: Bool) -> Docs.Doc
  at = token_index(c, node.name_span.start.offset) + 1
  if at < c.tokens.size and c.tokens[at].kind.ends_with?("-assign")
    case node.value
      Ast.Expr.Binary(binary) ->
        operator = source(c, c.tokens[at].span)
        return Docs.Doc.Concat([text("#{node.name} #{operator} "), expr_doc(c, binary.right, false)])
      _ -> at = at
    end
  end

  case node.type
    some(type) ->
      Docs.Doc.Concat([text("#{node.name}: "), type_doc(c, type), text(" = "), value_doc(c, node.value, forced)])
    none -> Docs.Doc.Concat([text("#{node.name} = "), value_doc(c, node.value, forced)])
  end
end

# A guard (`return x if c`) stays one when it fits on its line, and is written as the `if` it stands for when it does
# not or when it spans lines (a heredoc, a block of several lines): the parser takes a guard only when its `if` is on
# the line where its statement starts. An `if` that could be a guard (`guardable?`) takes the same choice, so the two
# forms meet at the same width and formatting again changes nothing.
def if_doc(c: Context, node: Ast.IfStmt) -> Docs.Doc
  return spelled_if_doc(c, node) if not node.guard and not guard_shaped?(c, node)

  guard = guard_doc(c, node)
  return spelled_if_doc(c, node) if not node.guard and not one_line?(guard)

  Docs.Doc.Group([Docs.Doc.IfBreak([spelled_if_doc(c, node)], [guard])])
end

# The one-line form of an `if` with one branch of one statement: `statement if condition`. The statement is laid out
# as in a body (`forced`), so a pipe chain of two or more `|>`, which a body breaks, breaks the guard too, and the
# guard is then written as its `if`. A method chain with a `.` at the start of each line is joined when it fits, as
# in a body.
def guard_doc(c: Context, node: Ast.IfStmt) -> Docs.Doc
  branch = node.branches[0]
  Docs.Doc.Concat([statement_doc(c, branch.body[0], true), text(" if "), expr_doc(c, branch.condition, false)])
end

# `if`, its `elsif` branches and its `else`. A comment before `elsif` or `else` stays just before the keyword, at the
# indent of the `if`; a comment after `else` on its line stays there.
def spelled_if_doc(c: Context, node: Ast.IfStmt) -> Docs.Doc
  key = Comments.key_of("IfStmt", node.span)
  dangling = c.dangling.get(key, [])
  parts: List[Docs.Doc] = []
  at = 0
  while at < node.branches.size
    branch = node.branches[at]
    keyword = "if "
    if at > 0
      keyword = "elsif "
      low = node.branches[at - 1].span.start.offset
      before = tagged(dangling, "elsif", low, branch.span.start.offset)
      parts = parts.concat(keyword_comments(before))
      parts = parts.push(Docs.Doc.HardLine)
    end

    items = statement_items(c, branch.body)
    if at == node.branches.size - 1 and node.else_body.none?
      items = items.concat(end_items(dangling))
    end

    head = commented(
      c,
      Comments.key_of("IfBranch", branch.span),
      Docs.Doc.Concat([text(keyword), expr_doc(c, branch.condition, false)]),
    )

    parts = parts.concat([head, body(c, items)])
    at += 1
  end

  case node.else_body
    some(stmts) ->
      else_at = else_offset(c, node)
      before = tagged(dangling, "else", -1, else_at)
      after = tagged(dangling, "else", else_at, node.span.stop.offset)
      parts = parts.concat(keyword_comments(before)).concat([Docs.Doc.HardLine, text("else")])
      items: List[Item] = []
      for placed in after
        if placed.comment.own_line
          items = items.push(comment_item(placed.comment))
        else
          parts = parts.push(Docs.Doc.LineSuffix(" " + placed.comment.text))
        end
      end

      items = items.concat(statement_items(c, stmts)).concat(end_items(dangling))
      parts = parts.push(body(c, items))
    none -> parts = parts
  end

  Docs.Doc.Concat(parts.concat([Docs.Doc.HardLine, text("end")]))
end

# The dangling comments tagged `keyword` that start after `low` and before `high`.
def tagged(dangling: List[Comments.Attached], keyword: String, low: Int, high: Int) -> List[Comments.Attached]
  dangling.select do |placed: Comments.Attached|
    offset = placed.comment.span.start.offset
    placed.keyword == keyword and offset > low and offset < high
  end
end

def keyword_comments(placed: List[Comments.Attached]) -> List[Docs.Doc]
  parts: List[Docs.Doc] = []
  for one in placed
    parts = parts.concat([Docs.Doc.HardLine, Docs.Doc.Comment(one.comment.text)])
  end

  parts
end

# The dangling comments that go at the end of the last body: before `end`, or with no keyword.
def end_items(dangling: List[Comments.Attached]) -> List[Item]
  kept = dangling.select do |placed: Comments.Attached| placed.keyword == "end" or placed.keyword == "" end
  kept.map do |placed: Comments.Attached| closing_item(placed.comment) end
end

# The offset of the `else` of an `if`: its `else` token, outside the blocks nested in it.
def else_offset(c: Context, node: Ast.IfStmt) -> Int
  at = token_index(c, node.span.start.offset)
  found = -1
  depth = 0
  while at < c.tokens.size and c.tokens[at].span.start.offset < node.span.stop.offset
    kind = c.tokens[at].kind
    if kind == "if" or kind == "while" or kind == "for" or kind == "case" or kind == "do" or kind == "def"
      depth += 1
    elsif kind == "end"
      depth -= 1
    elsif kind == "else" and depth == 1
      found = c.tokens[at].span.start.offset
    end

    at += 1
  end

  found
end

def case_doc(c: Context, node: Ast.CaseStmt) -> Docs.Doc
  key = Comments.key_of("CaseStmt", node.span)
  items: List[Item] = []
  for arm in node.arms
    arm_key = Comments.key_of("CaseArm", arm.span)
    items = items.concat(node_items(c, arm_key, arm.span.start.line, last_line(c, arm.span), arm_doc(c, arm)))
  end

  items = items.concat(dangling_items(c, key))
  head = Docs.Doc.Concat([text("case "), expr_doc(c, node.value, false), text(optional_do(c, node.value))])
  Docs.Doc.Concat([head, body(c, items), Docs.Doc.HardLine, text("end")])
end

# " do" when the source writes the optional `do` after the header expression of a `while`, `for` or `case`.
def optional_do(c: Context, header: Ast.Expr) -> String
  at = token_index(c, tight(c, Ast.expr_span(header)).stop.offset)
  return " do" if at < c.tokens.size and c.tokens[at].kind == "do"

  ""
end

# An arm: `pattern -> statement` on one line when its body is one simple statement that fits, else the body on the
# lines below. The pattern and the guard are copied: the guard must stay on the line of its pattern.
def arm_doc(c: Context, arm: Ast.CaseArm) -> Docs.Doc
  patterns = Ast.alternatives(arm.pattern)
  head = patterns.map do |pattern: Ast.Pattern| source(c, tight(c, Ast.pattern_span(pattern))) end.join(", ")
  case arm.guard
    some(guard) -> head = "#{head} if #{source(c, tight(c, Ast.expr_span(guard)))}"
    none -> head = head
  end

  head = head + " ->"
  arm_key = Comments.key_of("CaseArm", arm.span)
  # The pattern and the guard are copied as text, so their comments go above the arm or after the arrow.
  if patterns.size > 1
    patterns = [arm.pattern].concat(patterns)
  end

  keys = patterns.map do |pattern: Ast.Pattern|
    Comments.key_of(Comments.pattern_kind(pattern), Ast.pattern_span(pattern))
  end

  case arm.guard
    some(guard) -> keys = keys.push(Comments.key_of(Comments.expr_kind(guard), Ast.expr_span(guard)))
    none -> keys = keys
  end

  above: List[Docs.Doc] = []
  after: List[Docs.Doc] = []
  for key in keys
    for comment in c.leading.get(key, []).concat(c.trailing.get(key, []))
      if comment.own_line
        above = above.concat([Docs.Doc.Comment(comment.text), Docs.Doc.HardLine])
      else
        after = after.push(Docs.Doc.LineSuffix(" " + comment.text))
      end
    end
  end

  if arm.body.size == 1 and inline?(c, arm.body[0]) and after.size == 0
    stmt = arm.body[0]
    span = Ast.stmt_span(stmt)
    key = Comments.key_of(Comments.stmt_kind(stmt), span)
    found = around(c, key)
    if found.before.size == 0 and c.trailing.get(key, []).all? do |comment: Tokens.Comment| !comment.own_line end
      suffixes = c.trailing.get(key, []).map do |comment: Tokens.Comment| Docs.Doc.LineSuffix(" " + comment.text) end
      line = Docs.Doc.Group([text(head), Docs.Doc.Indent([Docs.Doc.Line, statement_doc(c, stmt, false)])])
      return Docs.Doc.Concat(above.push(line).concat(suffixes).concat(dangling_end(c, arm_key)))
    end
  end

  items = statement_items(c, arm.body).concat(dangling_items(c, arm_key))
  Docs.Doc.Concat(above.push(text(head)).concat(after).push(body(c, items)))
end

def dangling_end(c: Context, key: String) -> List[Docs.Doc]
  items = dangling_items(c, key)
  return [] if items.size == 0

  [Docs.Doc.Indent([Docs.Doc.HardLine, sequence(c, items)])]
end

# A statement that may share the line of a `case` arm or of a one-line `do` block: a simple one, or a guard (or an
# `if` that becomes one), which writes itself out as an `if` on lines of its own when it does not fit.
def inline?(c: Context, stmt: Ast.Stmt) -> Bool
  case stmt
    Ast.Stmt.If(node) -> node.guard or guardable?(c, node)
    _ -> simple?(stmt)
  end
end

# An `if c` whose body is one `return`, `break` or `next`, with no `elsif` or `else`, no comment from its `if` line to
# its `end` line, and a guard that can be one line: written as a guard when that fits on the line (if_doc).
def guardable?(c: Context, node: Ast.IfStmt) -> Bool
  return false if not guard_shaped?(c, node)

  one_line?(guard_doc(c, node))
end

# The shape of `guardable?`: one branch of one `return`, `break` or `next`, no `else`, no comment.
def guard_shaped?(c: Context, node: Ast.IfStmt) -> Bool
  return false if node.branches.size != 1 or node.else_body.some? or node.branches[0].body.size != 1

  return false if not exit?(node.branches[0].body[0])

  last = last_line(c, node.span)
  not (node.span.start.line..last).to_a.any? do |line: Int| c.noted.include?(line) end
end

# The body of a def whose result is not written `Void`, with each `return value` that the parser would read back
# from the bare value (its tail_returns) marked implicit, so that statement_doc writes the value without `return`:
# the last statement, and the last of each branch of a last `if` with `else` and of each arm of a last `case`, at any
# depth. The mark keeps the node and its span, so its comments stay where they were. A `try` value keeps `return`
# (statement_doc), and so does a `case` value: written bare, it would read back as a `case` statement.
def tail_values(stmts: List[Ast.Stmt]) -> List[Ast.Stmt]
  return stmts if stmts.size == 0

  last = stmts.size - 1
  stmts.set(last, tail_value(stmts[last]))
end

def tail_value(stmt: Ast.Stmt) -> Ast.Stmt
  case stmt
    Ast.Stmt.Return(node) ->
      case node.value
        some(value) ->
          case value
            Ast.Expr.Case(_) -> stmt
            _ -> Ast.Stmt.Return(node.with(implicit: true))
          end

        none -> stmt
      end

    Ast.Stmt.If(node) ->
      case node.else_body
        some(body) ->
          branches = node.branches.map do |branch: Ast.IfBranch| branch.with(body: tail_values(branch.body)) end
          Ast.Stmt.If(node.with(branches: branches, else_body: some(tail_values(body))))
        none -> stmt
      end

    Ast.Stmt.Case(node) ->
      arms = node.arms.map do |arm: Ast.CaseArm| arm.with(body: tail_values(arm.body)) end
      Ast.Stmt.Case(node.with(arms: arms))
    _ -> stmt
  end
end

# The names of the type aliases of the file that stand for Void, directly or through another such alias. In a def
# whose result is one, the checker reads the last expression as a statement, so `return 5` (a CHECK-TYPE-MISMATCH)
# written as `5` would check: the def keeps its `return`. An alias imported from another file is not seen here.
def void_aliases(decls: List[Ast.Decl]) -> List[String]
  aliases = decls.flat_map do |decl: Ast.Decl| alias_of(decl) end
  found = ["Void"]
  grown = true
  while grown
    grown = false
    for node in aliases
      if not found.include?(node.name) and node.target.args.size == 0 and found.include?(node.target.name)
        found = found.push(node.name)
        grown = true
      end
    end
  end

  found.drop(1)
end

# A result written `Void`, or an alias of Void declared in the file, with type arguments or not (`type V[T] = Void`).
def void_result?(c: Context, result: Ast.TypeRef) -> Bool
  return result.args.size == 0 if result.name == "Void"

  c.void_aliases.include?(result.name)
end

def alias_of(decl: Ast.Decl) -> List[Ast.TypeAliasDecl]
  case decl
    Ast.Decl.Export(node) -> alias_of(node.declaration)
    Ast.Decl.TypeAlias(node) -> [node]
    Ast.Decl.Module(node) -> node.declarations.flat_map do |inner: Ast.Decl| alias_of(inner) end
    _ -> []
  end
end

# A `try` value: a one-line def can give it, but a `try` at the end of a body is a statement and gives no value (the
# parser's tail_returns), so a body written for that def keeps `return`.
def try?(value: Ast.Expr) -> Bool
  case value
    Ast.Expr.Try(_) -> true
    _ -> false
  end
end

# Whether `doc` laid out with no width limit is one line. This reads the layout and not the source, so an `if` whose
# statement the formatter joins onto one line is a guard already on the first run, and a heredoc, a block of several
# statements or a value that a body breaks keeps the `if`.
def one_line?(doc: Docs.Doc) -> Bool = not Docs.render(doc, UNLIMITED).strip.include?("\n")

# A `return`, `break` or `next`: the statements that take a guard.
def exit?(stmt: Ast.Stmt) -> Bool
  case stmt
    Ast.Stmt.Return(_) -> true
    Ast.Stmt.Control(_) -> true
    _ -> false
  end
end

def simple?(stmt: Ast.Stmt) -> Bool
  case stmt
    Ast.Stmt.Binding(_) -> true
    Ast.Stmt.Return(_) -> true
    Ast.Stmt.Expression(_) -> true
    Ast.Stmt.Control(_) -> true
    _ -> false
  end
end

# ---- Expressions ----

# An expression with its comments. `bracketed` says that it sits directly inside brackets (an argument, an element, an
# entry or an operand of a broken expression), where a line break needs no parentheses of its own.
def expr_doc(c: Context, expr: Ast.Expr, bracketed: Bool) -> Docs.Doc
  key = Comments.key_of(Comments.expr_kind(expr), Ast.expr_span(expr))
  commented(c, key, bare(c, expr, bracketed))
end

def bare(c: Context, expr: Ast.Expr, bracketed: Bool) -> Docs.Doc
  case expr
    Ast.Expr.Literal(node) -> lone(literal(c, node.span), node.span, c, bracketed)
    Ast.Expr.Name(node) -> text(node.name)
    Ast.Expr.Call(node) ->
      return pipe_doc(c, expr, bracketed, false) if node.piped

      call_doc(c, node)
    Ast.Expr.EnumConstructor(node) ->
      name = text("#{node.enum_name}.#{node.variant_name}")
      return name if node.args.size == 0 and not source(c, node.span).ends_with?(")")

      Docs.Doc.Concat([name, arguments(c, node.args, Comments.key_of("EnumConstructor", node.span))])
    Ast.Expr.FunctionRef(node) -> text("&#{node.name}")
    Ast.Expr.Construct(node) ->
      named = node.args.map do |arg: Ast.NamedArg| named_doc(c, arg) end
      dangling = dangling_comments(c, Comments.key_of("Construct", node.span))
      listed(text("#{node.type_name}("), named, text(")"), dangling)
    Ast.Expr.ListLit(node) ->
      elements = node.elements.map do |element: Ast.Expr| expr_doc(c, element, true) end
      starts = node.elements.map do |element: Ast.Expr| Ast.expr_span(element).start.line end
      packed = shared_line?(starts) and node.elements.all? do |element: Ast.Expr| atomic?(c, element) end
      dangling = dangling_comments(c, Comments.key_of("ListLit", node.span))
      packed_list(text("["), elements, text("]"), dangling, packed)
    Ast.Expr.MapLit(node) ->
      entries = node.entries.map do |entry: Ast.MapEntry| entry_doc(c, entry) end
      starts = node.entries.map do |entry: Ast.MapEntry| entry.span.start.line end
      packed = shared_line?(starts) and node.entries.all? do |entry: Ast.MapEntry| atomic_entry?(c, entry) end
      dangling = dangling_comments(c, Comments.key_of("MapLit", node.span))
      packed_list(text("{"), entries, text("}"), dangling, packed)
    Ast.Expr.Interpolation(node) -> lone(literal(c, node.span), node.span, c, bracketed)
    Ast.Expr.EagLit(node) -> lone(literal(c, node.span), node.span, c, bracketed)
    Ast.Expr.BlockLit(node) -> block_doc(c, node)
    Ast.Expr.Case(node) -> case_doc(c, node)
    Ast.Expr.Try(node) ->
      return pipe_doc(c, expr, bracketed, false) if piped?(node.operand)

      Docs.Doc.Concat([text("try "), operand(c, node.operand, UNARY_LEVEL)])
    Ast.Expr.Unary(node) ->
      operator = source(c, node.op_span)
      if operator.length > 1
        operator = operator + " "
      end

      Docs.Doc.Concat([text(operator), operand(c, node.operand, UNARY_LEVEL)])
    Ast.Expr.Binary(node) -> binary_doc(c, node, bracketed)
    Ast.Expr.TypeName(node) -> type_doc(c, Ast.TypeRef(id: node.id, name: node.name, args: node.args, span: node.span))
    Ast.Expr.MethodCall(_) -> chain_doc(c, expr, bracketed)
    Ast.Expr.FieldAccess(_) -> chain_doc(c, expr, bracketed)
    Ast.Expr.Invoke(_) -> chain_doc(c, expr, bracketed)
    Ast.Expr.Update(_) -> chain_doc(c, expr, bracketed)
    Ast.Expr.Index(_) -> chain_doc(c, expr, bracketed)
    _ -> text(source(c, Ast.expr_span(expr)))
  end
end

# Whether an element is a short atom that a table packs: a literal, a name, a dotted name (`options.style`), a negative
# number or a variant without arguments, with no comment.
def atomic?(c: Context, expr: Ast.Expr) -> Bool
  key = Comments.key_of(Comments.expr_kind(expr), Ast.expr_span(expr))
  return false if c.leading.get(key, []).size > 0 or c.trailing.get(key, []).size > 0

  case expr
    Ast.Expr.Literal(node) -> not source(c, node.span).starts_with?("<<~")
    Ast.Expr.Name(_) -> true
    Ast.Expr.TypeName(_) -> true
    Ast.Expr.FunctionRef(_) -> true
    Ast.Expr.FieldAccess(node) -> atomic?(c, node.target)
    Ast.Expr.Unary(node) -> atomic?(c, node.operand)
    Ast.Expr.EnumConstructor(node) -> node.args.size == 0
    _ -> false
  end
end

# Whether two items start on one line: a table the author packed, which stays packed.
def shared_line?(starts: List[Int]) -> Bool
  at = 1
  while at < starts.size
    return true if starts[at] == starts[at - 1]

    at += 1
  end

  false
end

def atomic_entry?(c: Context, entry: Ast.MapEntry) -> Bool
  key = Comments.key_of("MapEntry", entry.span)
  quiet = c.leading.get(key, []).size == 0 and c.trailing.get(key, []).size == 0
  quiet and atomic?(c, entry.key) and atomic?(c, entry.value)
end

# A literal as written. A heredoc keeps its opener here and its body after the line.
def literal(c: Context, span: Source.Span) -> Docs.Doc
  written = source(c, span)
  if written.starts_with?("<<~")
    return Docs.Doc.Concat([text(written), Docs.Doc.After(c.heredocs.get(span.start.offset, []))])
  end

  text(written)
end

# A string that cannot break, outside brackets: on the next line in parentheses when it does not fit after what comes
# before it, as the repo writes a long message.
def lone(doc: Docs.Doc, span: Source.Span, c: Context, bracketed: Bool) -> Docs.Doc
  return doc if bracketed or source(c, span).starts_with?("<<~")

  wrapped([doc], false)
end

# The value of a statement: an expression, with a pipe chain of two or more `|>` forced to break when `forced`. A
# method chain that the source wrote with a dot at the start of each line and no parentheses stays that way.
def value_doc(c: Context, expr: Ast.Expr, forced: Bool) -> Docs.Doc
  if forced and dotted?(c, expr)
    key = Comments.key_of(Comments.expr_kind(expr), Ast.expr_span(expr))
    return commented(c, key, chain_of(c, expr, false, true))
  end

  if forced and (piped?(expr) or piped_try?(expr))
    key = Comments.key_of(Comments.expr_kind(expr), Ast.expr_span(expr))
    return commented(c, key, pipe_doc(c, expr, false, true))
  end

  expr_doc(c, expr, false)
end

# Whether `expr`, the whole value of a statement, is a method chain written with a `.` that starts a line (the parser
# reads it as a continuation of the line before). Each call, field or `.call` of the chain has its dot right after the
# end of its receiver (past the `)` of a parenthesized one), so the dots of the arguments and of the blocks, which sit
# inside the links and not between them, never count. A chain that the source wrote inside its own parentheses,
# `(a\n  .b)`, is left to the layout, which keeps them.
def dotted?(c: Context, expr: Ast.Expr) -> Bool
  span = tight(c, Ast.expr_span(expr))
  first = token_index(c, span.start.offset)
  after = token_index(c, span.stop.offset)
  if first > 0 and after < c.tokens.size
    return false if c.tokens[first - 1].kind == "left-paren" and c.tokens[after].kind == "right-paren"
  end

  current = expr
  found = false
  while link?(current)
    receiver = target_of(current)
    at = token_index(c, tight(c, Ast.expr_span(receiver)).stop.offset)
    while at < c.tokens.size and c.tokens[at].kind == "right-paren"
      at += 1
    end

    if at > 0 and at < c.tokens.size and c.tokens[at].kind == "dot"
      found = found or c.tokens[at].span.start.line > c.tokens[at - 1].span.stop.line
    end

    current = receiver
  end

  found
end

# The level of an expression, for the parentheses: a binary operator's, a range's (0), a pipe's, a prefix's or a
# postfix or primary expression's.
def level(expr: Ast.Expr) -> Int
  case expr
    Ast.Expr.Binary(node) -> LEVELS.get(node.op, 0)
    Ast.Expr.Call(node) ->
      return PIPE_LEVEL if node.piped

      POSTFIX_LEVEL
    Ast.Expr.Try(node) ->
      return PIPE_LEVEL if piped?(node.operand)

      UNARY_LEVEL
    Ast.Expr.Unary(_) -> UNARY_LEVEL
    _ -> POSTFIX_LEVEL
  end
end

def piped_try?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Try(node) -> piped?(node.operand)
    _ -> false
  end
end

def piped?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Call(node) -> node.piped
    _ -> false
  end
end

# Whether an operand of `op` keeps parentheses that the precedence does not need, for the reader: an `and` inside an
# `or`, a comparison inside another (`(a > b) == (b > n)`), and a `*`, `/` or `%` inside another of them.
def clarify?(op: String, child: Ast.Expr) -> Bool
  case child
    Ast.Expr.Binary(node) ->
      return true if op == "or" and node.op == "and"

      return true if comparison?(op) and comparison?(node.op)

      LEVELS.get(op, 0) == 7 and LEVELS.get(node.op, 0) == 7 and op != node.op
    _ -> false
  end
end

def comparison?(op: String) -> Bool = LEVELS.get(op, 0) == 3 or LEVELS.get(op, 0) == 4

def binary?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Binary(_) -> true
    _ -> false
  end
end

# An operand in parentheses when it is looser than `minimum` or when `force` asks for them.
def clear(c: Context, expr: Ast.Expr, minimum: Int, force: Bool) -> Docs.Doc
  return operand(c, expr, POSTFIX_LEVEL + 1) if force

  operand(c, expr, minimum)
end

# An operand that needs the level `minimum`: in parentheses when it is looser. Inside them, or inside the operator's
# own broken form, a line break needs no more parentheses.
def operand(c: Context, expr: Ast.Expr, minimum: Int) -> Docs.Doc
  return expr_doc(c, expr, true) if level(expr) >= minimum

  Docs.Doc.Group([
    text("("),
    Docs.Doc.Indent([Docs.Doc.SoftLine, expr_doc(c, expr, true)]),
    Docs.Doc.SoftLine,
    text(")"),
  ])
end

# A broken expression: as it is inside brackets, else in parentheses of its own that only a broken layout shows,
# with its lines two spaces deeper.
def wrapped(parts: List[Docs.Doc], bracketed: Bool) -> Docs.Doc
  return Docs.Doc.Group(parts) if bracketed

  Docs.Doc.Group([
    Docs.Doc.IfBreak([text("(")], []),
    Docs.Doc.Indent([Docs.Doc.SoftLine].concat(parts)),
    Docs.Doc.SoftLine,
    Docs.Doc.IfBreak([text(")")], []),
  ])
end

# A chain of one binary level, such as `a + b - c`, with each operator at the end of its line when it breaks (47.5
# rule 7). A range is printed whole.
def binary_doc(c: Context, node: Ast.Binary, bracketed: Bool) -> Docs.Doc
  operator = source(c, node.op_span)
  this = LEVELS.get(node.op, 0)
  if this == 0
    return Docs.Doc.Concat([
      clear(c, node.left, 1, binary?(node.left)),
      text(operator),
      clear(c, node.right, 1, binary?(node.right)),
    ])
  end

  # The left spine of the same level: `a + b - c` is (a + b) - c.
  spine: List[Ast.Binary] = [node]
  left = node.left
  looping = this != 3 and this != 4
  while looping
    looping = false
    case left
      Ast.Expr.Binary(inner) ->
        if LEVELS.get(inner.op, 0) == this and (this != 7 or inner.op == node.op)
          spine = spine.push(inner)
          left = inner.left
          looping = true
        end

      _ -> looping = false
    end
  end

  minimum = this
  if this == 3 or this == 4
    minimum = this + 1
  end

  first = clear(c, left, minimum, clarify?(spine[spine.size - 1].op, left))
  parts: List[Docs.Doc] = []
  at = spine.size - 1
  while at >= 0
    link = spine[at]
    right = clear(c, link.right, this + 1, clarify?(link.op, link.right))
    if at < spine.size - 1
      # An inner node of the spine ends where its right operand ends; its comments go around it.
      found = around(c, Comments.key_of("Binary", spine[at + 1].span))
      parts = parts.concat(found.after)
      first = Docs.Doc.Concat(found.before.push(first))
    end

    parts = parts.concat([text(" " + source(c, link.op_span)), Docs.Doc.Line, right])
    at -= 1
  end

  wrapped([first].concat(parts), bracketed)
end

# A pipe chain, `x |> f() |> g()`, with each `|>` at the start of its line when it breaks, as the repo writes it. With
# `forced` (the whole value of a statement), a chain of two or more `|>` breaks even when it fits.
def pipe_doc(c: Context, expr: Ast.Expr, bracketed: Bool, forced: Bool) -> Docs.Doc
  stages: List[Docs.Doc] = []
  current = expr
  looping = true
  while looping
    looping = false
    key = Comments.key_of(Comments.expr_kind(current), Ast.expr_span(current))
    case Comments.pipe_stage(current)
      some(stage) ->
        stage_key = Comments.key_of("PipeStage", stage.call.span)
        shown = call_doc_keyed(c, stage.call.with(args: stage.call.args.drop(1), parenthesized: true), stage_key)
        mark = "|> "
        if stage.tried
          mark = "|> try "
        end

        piece = commented(c, stage_key, Docs.Doc.Concat([text(mark), shown]))
        if stages.size > 0
          piece = commented(c, key, piece)
        end

        stages = List.concat([piece], stages)
        current = stage.call.args[0]
        looping = true

      none -> looping = false
    end
  end

  # A single stage stays on its line when it fits.
  parts: List[Docs.Doc] = [operand(c, current, PIPE_LEVEL)]
  if forced and stages.size >= 2
    parts = parts.push(Docs.Doc.BreakParent)
  end

  for stage in stages
    parts = parts.concat([Docs.Doc.Line, stage])
  end

  wrapped(parts, bracketed)
end

# A call by name: `f(args)`, `puts x` without parentheses, and a trailing `do` block.
def call_doc(c: Context, node: Ast.Call) -> Docs.Doc = call_doc_keyed(c, node, Comments.key_of("Call", node.span))

# `call_doc`, where `key` holds the dangling comments of an empty argument list: the call's own, or its pipe stage's.
def call_doc_keyed(c: Context, node: Ast.Call, key: String) -> Docs.Doc
  args = node.args
  block: List[Docs.Doc] = []
  if args.size > 0
    case args[args.size - 1]
      Ast.Expr.BlockLit(_) ->
        block = [text(" "), expr_doc(c, args[args.size - 1], false)]
        args = args.take(args.size - 1)
      _ -> block = block
    end
  end

  return Docs.Doc.Concat([text(call_name(c, node)), arguments(c, args, key)].concat(block)) if node.parenthesized

  return Docs.Doc.Concat([text(node.name)].concat(block)) if args.size == 0

  shown = args.map do |arg: Ast.Expr| expr_doc(c, arg, true) end
  Docs.Doc.Concat([text(node.name + " "), join(shown, [text(", ")])].concat(block))
end

# The name of a call as the source wrote it: the parser reads `Result.Ok(x)` and `Result.Err(x)` as the calls `ok`
# and `error`, and the formatter keeps either form.
def call_name(c: Context, node: Ast.Call) -> String
  return node.name if node.piped or (node.name != "ok" and node.name != "error")

  at = token_index(c, node.span.start.offset)
  if at < c.tokens.size and c.tokens[at].lexeme == "Result"
    return "Result.Ok" if node.name == "ok"

    return "Result.Err"
  end

  node.name
end

# The arguments of a call. A sole argument that is a list or map literal hugs the parentheses, `Set.new([`, and
# breaks inside its own brackets.
def arguments(c: Context, args: List[Ast.Expr], key: String) -> Docs.Doc
  shown = args.map do |arg: Ast.Expr| expr_doc(c, arg, true) end
  return Docs.Doc.Concat([text("("), shown[0], text(")")]) if args.size == 1 and huggable?(c, args[0])

  listed(text("("), shown, text(")"), dangling_comments(c, key))
end

def huggable?(c: Context, expr: Ast.Expr) -> Bool
  key = Comments.key_of(Comments.expr_kind(expr), Ast.expr_span(expr))
  return false if c.leading.get(key, []).size > 0 or c.trailing.get(key, []).size > 0

  case expr
    Ast.Expr.ListLit(node) -> node.elements.size > 0
    Ast.Expr.MapLit(node) -> node.entries.size > 0
    _ -> false
  end
end

def named_doc(c: Context, arg: Ast.NamedArg) -> Docs.Doc
  doc = Docs.Doc.Concat([text("#{arg.name}: "), expr_doc(c, arg.value, false)])
  commented(c, Comments.key_of("NamedArg", arg.span), doc)
end

def entry_doc(c: Context, entry: Ast.MapEntry) -> Docs.Doc
  doc = Docs.Doc.Concat([expr_doc(c, entry.key, true), text(": "), expr_doc(c, entry.value, false)])
  commented(c, Comments.key_of("MapEntry", entry.span), doc)
end

# A method chain: the receiver, then each `.name(args)`, `.name`, `.call(args)`, `.with(...)` or `[index]`. A chain
# with two calls or more breaks before each `.` when it does not fit (47.5 rule 10): the first call stays with a
# receiver that is a plain name.
def chain_doc(c: Context, expr: Ast.Expr, bracketed: Bool) -> Docs.Doc = chain_of(c, expr, bracketed, false)

# `chain_doc`, where `open` says that the chain breaks with leading dots alone, with no parentheses of its own.
def chain_of(c: Context, expr: Ast.Expr, bracketed: Bool, open: Bool) -> Docs.Doc
  links: List[Link] = []
  current = expr
  looping = true
  outer = true
  while looping
    key = Comments.key_of(Comments.expr_kind(current), Ast.expr_span(current))
    found = link_of(c, current)
    case found
      some(link) ->
        shown = link
        if not outer
          shown = link.with(doc: commented(c, key, Docs.Doc.Concat([link.doc].concat(link.block))), block: [])
        end

        links = List.concat([shown], links)
        current = target_of(current)
        outer = false
      none -> looping = false
    end
  end

  head = operand(c, current, POSTFIX_LEVEL)
  first = 0
  plain = false
  case current
    Ast.Expr.Name(_) -> plain = true
    Ast.Expr.TypeName(_) -> plain = true
    _ -> plain = false
  end

  if plain and links.size > 0
    first = 1
    while first < links.size and not links[first].breaks
      first += 1
    end
  end

  # The trailing block of the last call stays out of the chain's group: its body does not break the chain.
  tail: List[Docs.Doc] = []
  if links.size > 0
    tail = links[links.size - 1].block
  end

  calls = links.select do |link: Link| link.call end
  if calls.size < 2 or first >= links.size
    return Docs.Doc.Concat([head].concat(links.map do |link: Link| link.doc end).concat(tail))
  end

  start: List[Docs.Doc] = [head].concat(links.take(first).map do |link: Link| link.doc end)
  rest: List[Docs.Doc] = []
  for link in links.drop(first)
    if link.breaks
      rest = rest.push(Docs.Doc.SoftLine)
    end

    rest = rest.push(link.doc)
  end

  if tail.size > 0
    # A block cannot follow a closing parenthesis, so this chain breaks with leading dots alone, which continue a line.
    # The block sits in the chain's group, a level deeper when the chain breaks so that its body and `end` follow the
    # line of its call; the break its body asks for goes before the group, for the groups around the chain only.
    lifted = tail.map do |part: Docs.Doc| unbroken(part) end
    parts = start.concat([Docs.Doc.Indent(rest), Docs.Doc.IfBreak([Docs.Doc.Indent(lifted)], lifted)])
    before: List[Docs.Doc] = []
    if tail.any? do |part: Docs.Doc| broken?(part) end
      before = [Docs.Doc.BreakParent]
    end

    return Docs.Doc.Concat(before.push(Docs.Doc.Group(parts)))
  end

  return Docs.Doc.Group(start.push(Docs.Doc.Indent(rest))) if open

  wrapped(start.push(Docs.Doc.Indent(rest)), bracketed)
end

def link_of(c: Context, expr: Ast.Expr) -> Optional[Link]
  case expr
    Ast.Expr.MethodCall(node) -> some(method_link(c, node))
    Ast.Expr.FieldAccess(node) -> some(Link(doc: text(".#{node.name}"), block: [], call: false, breaks: true))
    Ast.Expr.Invoke(node) ->
      shown = Docs.Doc.Concat([text(".call"), arguments(c, node.args, Comments.key_of("Invoke", node.span))])
      some(Link(doc: shown, block: [], call: true, breaks: true))
    Ast.Expr.Update(node) ->
      named = node.args.map do |arg: Ast.NamedArg| named_doc(c, arg) end
      some(Link(doc: listed(text(".with("), named, text(")"), []), block: [], call: true, breaks: true))
    Ast.Expr.Index(node) ->
      inner = Docs.Doc.Group([
        text("["),
        Docs.Doc.Indent([Docs.Doc.SoftLine, expr_doc(c, node.index, true)]),
        Docs.Doc.SoftLine,
        text("]"),
      ])

      some(Link(doc: inner, block: [], call: false, breaks: false))
    _ -> none
  end
end

# Whether `expr` is one link of a chain: a call, a field, `.call`, `.with` or an index.
def link?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.MethodCall(_) -> true
    Ast.Expr.FieldAccess(_) -> true
    Ast.Expr.Invoke(_) -> true
    Ast.Expr.Update(_) -> true
    Ast.Expr.Index(_) -> true
    _ -> false
  end
end

def target_of(expr: Ast.Expr) -> Ast.Expr
  case expr
    Ast.Expr.MethodCall(node) -> node.target
    Ast.Expr.FieldAccess(node) -> node.target
    Ast.Expr.Invoke(node) -> node.target
    Ast.Expr.Update(node) -> node.target
    Ast.Expr.Index(node) -> node.target
    _ -> expr
  end
end

# `.name(args)`, with a trailing `do` block. A call whose only argument is a block keeps the `()` it was written with.
def method_link(c: Context, node: Ast.MethodCall) -> Link
  args = node.args
  block: List[Docs.Doc] = []
  if args.size > 0
    case args[args.size - 1]
      Ast.Expr.BlockLit(_) ->
        block = [text(" "), expr_doc(c, args[args.size - 1], false)]
        args = args.take(args.size - 1)
      _ -> block = block
    end
  end

  name = text(".#{node.name}")
  if args.size == 0 and block.size > 0
    at = token_index(c, node.name_span.start.offset) + 1
    if at >= c.tokens.size or c.tokens[at].kind != "left-paren"
      return Link(doc: name, block: block, call: true, breaks: true)
    end
  end

  shown = Docs.Doc.Concat([name, arguments(c, args, Comments.key_of("MethodCall", node.span))])
  Link(doc: shown, block: block, call: true, breaks: true)
end

# `do |params| body end`: on one line when the body is one simple statement with no comments and it fits, else with
# the body on the lines below.
def block_doc(c: Context, node: Ast.BlockLit) -> Docs.Doc
  key = Comments.key_of("BlockLit", node.span)
  head = "do"
  if node.params.size > 0
    params = node.params.map do |param: Ast.BlockParam| block_param(c, param) end
    head = "do |#{params.join(", ")}|"
  end

  # The parameters are text, so their comments go at the end of the `do` line or at the top of the body.
  suffixes: List[Docs.Doc] = []
  above: List[Item] = []
  for param in node.params
    keys = [Comments.key_of("BlockParam", param.span)]
    case param.type
      some(type) -> keys = keys.push(Comments.key_of("TypeRef", type.span))
      none -> keys = keys
    end

    for one in keys
      for comment in c.leading.get(one, []).concat(c.trailing.get(one, []))
        if comment.own_line
          above = above.push(comment_item(comment))
        else
          suffixes = suffixes.push(Docs.Doc.LineSuffix(" " + comment.text))
        end
      end
    end
  end

  quiet = suffixes.size == 0 and above.size == 0
  if quiet and node.body.size == 1 and inline?(c, node.body[0]) and c.dangling.get(key, []).size == 0
    stmt = node.body[0]
    stmt_key = Comments.key_of(Comments.stmt_kind(stmt), Ast.stmt_span(stmt))
    if c.leading.get(stmt_key, []).size == 0 and c.trailing.get(stmt_key, []).size == 0
      return Docs.Doc.Group([
        text(head),
        Docs.Doc.Indent([Docs.Doc.Line, statement_doc(c, stmt, false)]),
        Docs.Doc.Line,
        text("end"),
      ])
    end
  end

  # A body on its own lines breaks every group around the block, so the items next to it go on lines of their own.
  items = above.concat(statement_items(c, node.body)).concat(dangling_items(c, key))
  parts = [Docs.Doc.BreakParent, text(head)].concat(suffixes)
  Docs.Doc.Concat(parts.concat([body(c, items), Docs.Doc.HardLine, text("end")]))
end

# Whether a document starts with the break of a multi-line block body (`block_doc`).
def broken?(doc: Docs.Doc) -> Bool
  case doc
    Docs.Doc.BreakParent -> true
    Docs.Doc.Concat(parts) -> parts.size > 0 and broken?(parts[0])
    _ -> false
  end
end

# The document without the break it starts with.
def unbroken(doc: Docs.Doc) -> Docs.Doc
  case doc
    Docs.Doc.BreakParent -> Docs.Doc.Concat([])
    Docs.Doc.Concat(parts) ->
      return doc if parts.size == 0

      Docs.Doc.Concat([unbroken(parts[0])].concat(parts.drop(1)))
    _ -> doc
  end
end

# A block parameter as text; it has no layout of its own.
def block_param(c: Context, param: Ast.BlockParam) -> String
  case param.type
    some(type) -> "#{param.name}: #{type_text(type)}"
    none -> param.name
  end
end

def type_text(type: Ast.TypeRef) -> String
  return type.name if type.args.size == 0

  "#{type.name}[#{type.args.map do |arg: Ast.TypeRef| type_text(arg) end.join(", ")}]"
end

# The dangling comments of an empty list, call or literal.
def dangling_comments(c: Context, key: String) -> List[Tokens.Comment]
  c.dangling.get(key, []).map do |placed: Comments.Attached| placed.comment end
end

# Items between brackets: on one line when they fit, else one per line, two spaces deeper, with a trailing comma
# (47.5 rules 2 and 14). An empty list keeps its dangling comments inside, each on its own line.
def listed(open: Docs.Doc, items: List[Docs.Doc], close: Docs.Doc, dangling: List[Tokens.Comment]) -> Docs.Doc
  packed_list(open, items, close, dangling, false)
end

# Like `listed`; a `packed` list that breaks fills each line with as many items as fit, as a table of literals is
# written, instead of one item per line.
def packed_list(
  open: Docs.Doc,
  items: List[Docs.Doc],
  close: Docs.Doc,
  dangling: List[Tokens.Comment],
  packed: Bool,
) -> Docs.Doc
  if items.size == 0
    return Docs.Doc.Concat([open, close]) if dangling.size == 0

    lines: List[Docs.Doc] = []
    for comment in dangling
      lines = lines.concat([Docs.Doc.HardLine, Docs.Doc.Comment(comment.text)])
    end

    return Docs.Doc.Concat([open, Docs.Doc.Indent(lines), Docs.Doc.HardLine, close])
  end

  separator = [text(","), Docs.Doc.Line]
  joined = join(items, separator)
  if packed
    # Each item but the last carries its comma, so the fit of an item counts it.
    filled: List[Docs.Doc] = []
    at = 0
    while at < items.size
      if at < items.size - 1
        filled = filled.concat([Docs.Doc.Concat([items[at], text(",")]), Docs.Doc.Line])
      else
        filled = filled.push(items[at])
      end

      at += 1
    end

    joined = Docs.Doc.Fill(filled)
  end

  inner = [Docs.Doc.SoftLine, joined, Docs.Doc.IfBreak([text(",")], [])]
  Docs.Doc.Group([open, Docs.Doc.Indent(inner), Docs.Doc.SoftLine, close])
end

# ---- Helpers ----

def text(value: String) -> Docs.Doc = Docs.Doc.Text(value)

def join(items: List[Docs.Doc], separator: List[Docs.Doc]) -> Docs.Doc
  parts: List[Docs.Doc] = []
  at = 0
  while at < items.size
    if at > 0
      parts = parts.concat(separator)
    end

    parts = parts.push(items[at])
    at += 1
  end

  Docs.Doc.Concat(parts)
end

# A node the parser made without text of its own has an empty span.
def written?(span: Source.Span) -> Bool = span.stop.offset > span.start.offset

# The source text of a span.
def source(c: Context, span: Source.Span) -> String
  first = span.start.line
  last = span.stop.line
  return c.lines[first - 1].slice(span.start.column - 1, span.stop.column - span.start.column) if first == last

  line = c.lines[first - 1]
  parts = [line.slice(span.start.column - 1, line.length - span.start.column + 1)]
  at = first + 1
  while at < last
    parts = parts.push(c.lines[at - 1])
    at += 1
  end

  if last <= c.lines.size
    parts = parts.push(c.lines[last - 1].slice(0, span.stop.column - 1))
  end

  parts.join("\n")
end

# The span cut at its last token.
def tight(c: Context, span: Source.Span) -> Source.Span
  at = token_index(c, span.stop.offset) - 1
  while at >= 0 and c.tokens[at].span.stop.offset > span.stop.offset
    at -= 1
  end

  return span if at < 0 or c.tokens[at].span.stop.offset <= span.start.offset

  span.with(stop: c.tokens[at].span.stop)
end

# The line of the last token of a span.
def last_line(c: Context, span: Source.Span) -> Int = tight(c, span).stop.line

# The index of the first token that starts at or after `offset`.
def token_index(c: Context, offset: Int) -> Int
  low = 0
  high = c.starts.size
  while low < high
    middle = (low + high) / 2
    if c.starts[middle] < offset
      low = middle + 1
    else
      high = middle
    end
  end

  low
end

def trim_end(line: String) -> String
  stop = line.length
  while stop > 0 and (line.slice(stop - 1, 1) == " " or line.slice(stop - 1, 1) == "\t")
    stop -= 1
  end

  line.slice(0, stop)
end

def decl_span(decl: Ast.Decl) -> Source.Span
  case decl
    Ast.Decl.Import(node) -> node.span
    Ast.Decl.Reexport(node) -> node.span
    Ast.Decl.Export(node) -> node.span
    Ast.Decl.Function(node) -> node.span
    Ast.Decl.Struct(node) -> node.span
    Ast.Decl.Enum(node) -> node.span
    Ast.Decl.TypeAlias(node) -> node.span
    Ast.Decl.Resource(node) -> node.span
    Ast.Decl.Constant(node) -> node.span
    Ast.Decl.Module(node) -> node.span
  end
end

# ---- Docs, heredocs and extern blocks in the source ----

# The first line of the `##` block right above the line of `offset`'s node.
def doc_first(c: Context, offset: Int) -> Int
  at = token_index(c, offset) - 1
  return c.tokens[at].span.start.line if at >= 0 and c.tokens[at].kind == "DOC"

  # A doc without its token cannot happen; keep the node's own line.
  at = token_index(c, offset)
  c.tokens[at].span.start.line
end

# The last line of the `##` block that starts at `first`.
def doc_last(c: Context, first: Int) -> Int
  last = first
  while last < c.lines.size and c.lines[last].strip.starts_with?("##")
    last += 1
  end

  last
end

# The lines of the `##` block that starts at `first`, as written, each followed by a line break.
def doc_lines(c: Context, first: Int) -> List[Docs.Doc]
  parts: List[Docs.Doc] = []
  line = first
  last = doc_last(c, first)
  while line <= last
    parts = parts.concat([text(c.lines[line - 1].strip), Docs.Doc.HardLine])
    line += 1
  end

  parts
end

# The body of each heredoc by the offset of its opener: its lines after the line of the opener (after the end line of
# the heredoc before it on that line), up to its end line, as written.
def heredoc_bodies(lines: List[String], tokens: List[Tokens.Token]) -> Map[Int, List[String]]
  bodies: Map[Int, List[String]] = {}
  resume_line = 0
  for token in tokens
    start = token.span.start
    opener = lines[start.line - 1].slice(start.column - 1, lines[start.line - 1].length - start.column + 1)
    if opener.starts_with?("<<~") and not bodies.has_key?(start.offset)
      name = heredoc_name(opener)
      first = start.line + 1
      if resume_line > start.line
        first = resume_line
      end

      last = first
      while last <= lines.size and lines[last - 1].strip != name
        last += 1
      end

      body: List[String] = []
      at = first
      while at <= last and at <= lines.size
        body = body.push(lines[at - 1])
        at += 1
      end

      bodies = bodies.put(start.offset, body)
      resume_line = last + 1
    end
  end

  bodies
end

def heredoc_name(opener: String) -> String
  at = 3
  while at < opener.length and "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_".contains?(opener.slice(at, 1))
    at += 1
  end

  opener.slice(3, at - 3)
end

# The `extern` blocks: from a top-level `extern` followed by a string, or by the word module and a string, to the first
# line that is `end` at the left margin.
def extern_blocks(lines: List[String], tokens: List[Tokens.Token]) -> List[Extern]
  blocks: List[Extern] = []
  at = 0
  while at + 1 < tokens.size
    token = tokens[at]
    string = at + 1
    if tokens[string].kind == "name" and tokens[string].lexeme == "module" and string + 1 < tokens.size
      string += 1
    end

    next = tokens[string].kind
    library = next == "string" or next == "interp-start"
    if token.kind == "name" and token.lexeme == "extern" and token.span.start.column == 1 and library
      first = token.span.start.line
      last = first + 1
      while last <= lines.size and trim_end(lines[last - 1]) != "end"
        last += 1
      end

      stop = token.span.start.offset
      line = first
      while line <= last and line <= lines.size
        stop += lines[line - 1].length + 1
        line += 1
      end

      blocks = blocks.push(
        Extern(first: first, last: last, start: token.span.start.offset, stop: stop, before: [], after: []),
      )

      while at < tokens.size and tokens[at].span.start.offset < stop
        at += 1
      end
    else
      at += 1
    end
  end

  blocks
end

# The index of the extern block that holds `offset`, or -1.
def extern_at(blocks: List[Extern], offset: Int) -> Int
  at = 0
  while at < blocks.size
    return at if blocks[at].start <= offset and offset < blocks[at].stop

    at += 1
  end

  -1
end
