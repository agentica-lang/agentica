## The layout of the formatter (docs/future/47-formatter.md, 47.5): the document of a parsed file, with its comments
## where the attachment put them (47.4).
##
## The tree has no node for the text of a literal, so literals, interpolated strings, patterns and guards are copied
## from the source; a heredoc keeps its body byte for byte after the line of its opener. An `extern` block is copied
## whole, because the tree keeps only the Agentica types of its C types. Everything else is printed from the tree:
## the printer chooses the grouping parentheses from the precedence (47.5 rule 4), and a broken expression that is
## not already inside brackets gets its own.
##
## Between two items of a body (a declaration, a statement, a field, a variant, a `case` arm or a comment) a blank
## line stays when the source had one right before the second item, at most one, and none is added.

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

# One item of a body: its first and last source lines and its document.
struct Item
  first: Int
  last: Int
  doc: Docs.Doc
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
export def context(text: String, tokens: List[Tokens.Token], attachment: Comments.Attachment) -> Context
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

  return Context(
    lines: lines,
    tokens: kept,
    starts: starts,
    leading: leading,
    trailing: trailing,
    dangling: dangling,
    heredocs: heredoc_bodies(lines, kept),
    externs: externs,
  )
end

## The document of a file.
export def program_doc(c: Context, program: Ast.Program) -> Docs.Doc
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
    line = placed.comment.span.start.line
    items = items.push(Item(first: line, last: line, doc: Docs.Doc.Comment(placed.comment.text)))
  end

  return sequence(c, items)
end

# ---- Items, blank lines and comments ----

# The items joined by line breaks, with an empty line where the source had a blank line right before an item.
def sequence(c: Context, items: List[Item]) -> Docs.Doc
  parts: List[Docs.Doc] = []
  at = 0
  while at < items.size
    item = items[at]
    if at > 0
      parts = parts.push(Docs.Doc.HardLine)
      if blank_before?(c, item.first, items[at - 1].last)
        parts = parts.push(Docs.Doc.HardLine)
      end
    end

    parts = parts.push(item.doc)
    at += 1
  end

  return Docs.Doc.Concat(parts)
end

# Whether the line right before `first` is blank and comes after `last`.
def blank_before?(c: Context, first: Int, last: Int) -> Bool
  above = first - 1
  return above > last and above >= 1 and above <= c.lines.size and c.lines[above - 1].strip == ""
end

# The items of a node: its leading comments, the node with its comments after code, and the comments alone on their
# lines after it.
def node_items(c: Context, key: String, first: Int, last: Int, doc: Docs.Doc) -> List[Item]
  items: List[Item] = c.leading.get(key, []).map do |comment: Tokens.Comment| comment_item(comment) end
  suffixes: List[Docs.Doc] = []
  below: List[Item] = []
  for comment in c.trailing.get(key, [])
    if comment.own_line
      below = below.push(comment_item(comment))
    else
      suffixes = suffixes.push(Docs.Doc.LineSuffix(" " + comment.text))
    end
  end

  items = items.push(Item(first: first, last: last, doc: Docs.Doc.Concat([doc].concat(suffixes))))
  return items.concat(below)
end

def comment_item(comment: Tokens.Comment) -> Item
  line = comment.span.start.line
  return Item(first: line, last: line, doc: Docs.Doc.Comment(comment.text))
end

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

  return Around(before: before, after: after)
end

def commented(c: Context, key: String, doc: Docs.Doc) -> Docs.Doc
  found = around(c, key)
  if found.before.size == 0 and found.after.size == 0
    return doc
  end

  return Docs.Doc.Concat(found.before.push(doc).concat(found.after))
end

# The dangling comments of a node, each on its own line, as the items of an empty body.
def dangling_items(c: Context, key: String) -> List[Item]
  return c.dangling.get(key, []).map do |placed: Comments.Attached| comment_item(placed.comment) end
end

# A body two spaces deeper, from the line after its header; nothing for an empty body.
def body(c: Context, items: List[Item]) -> Docs.Doc
  if items.size == 0
    return Docs.Doc.Concat([])
  end

  return Docs.Doc.Indent([Docs.Doc.HardLine, sequence(c, items)])
end

# ---- Declarations ----

def decl_items(c: Context, decl: Ast.Decl) -> List[Item]
  span = decl_span(decl)
  key = Comments.key_of(Comments.decl_kind(decl), span)
  first = span.start.line
  parts: List[Docs.Doc] = []
  if has_doc?(decl)
    first = doc_first(c, span.start.offset)
    parts = doc_lines(c, first)
  end

  doc = Docs.Doc.Concat(parts.push(decl_doc(c, decl)))
  return node_items(c, key, first, last_line(c, span), doc)
end

def has_doc?(decl: Ast.Decl) -> Bool
  case decl
    Ast.Decl.Export(node) -> return node.doc.some?
    Ast.Decl.Function(node) -> return node.doc.some?
    Ast.Decl.Struct(node) -> return node.doc.some?
    Ast.Decl.Enum(node) -> return node.doc.some?
    Ast.Decl.TypeAlias(node) -> return node.doc.some?
    Ast.Decl.Constant(node) -> return node.doc.some?
    _ -> return false
  end
end

# A declaration without its doc, which `decl_items` prints before it.
def decl_doc(c: Context, decl: Ast.Decl) -> Docs.Doc
  case decl
    Ast.Decl.Import(node) -> return import_doc(c, node)
    Ast.Decl.Reexport(node) -> return text("export #{node.alias}.#{node.name}")
    Ast.Decl.Export(node) -> return Docs.Doc.Concat([text("export "), decl_doc(c, node.declaration)])
    Ast.Decl.Function(node) -> return function_doc(c, node)
    Ast.Decl.Struct(node) -> return struct_doc(c, node)
    Ast.Decl.Enum(node) -> return enum_doc(c, node)
    Ast.Decl.TypeAlias(node) ->
      return Docs.Doc.Concat([
        text("type #{node.name}#{type_parameters(node.type_parameters)} = "),
        type_doc(c, node.target),
      ])
    Ast.Decl.Resource(node) -> return text(source(c, node.span))
    Ast.Decl.Constant(node) -> return constant_doc(c, node)
  end
end

def import_doc(c: Context, node: Ast.ImportDecl) -> Docs.Doc
  path = import_path(c, node)
  case node.alias
    some(alias) -> return text("import #{alias} from #{path}")
    none ->
      names = node.names.map do |entry: Ast.ImportName| import_name(entry) end
      packed = shared_line?(node.names.map do |entry: Ast.ImportName| entry.span.start.line end)
      return Docs.Doc.Concat([packed_list(text("import {"), names, text("}"), [], packed), text(" from #{path}")])
  end
end

def import_name(entry: Ast.ImportName) -> Docs.Doc
  if entry.local == entry.name
    return text(entry.name)
  end

  return text("#{entry.name} as #{entry.local}")
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

  return found
end

def function_doc(c: Context, node: Ast.FunctionDecl) -> Docs.Doc
  key = Comments.key_of("FunctionDecl", node.span)
  params = node.params.map do |param: Ast.Param| param_doc(c, param) end
  head: List[Docs.Doc] = [
    text("def #{node.name}#{type_parameters(node.type_parameters)}"),
    listed(text("("), params, text(")"), []),
  ]
  if written?(node.result.span)
    head = head.concat([text(" -> "), type_doc(c, node.result)])
  end

  items = statement_items(c, node.body).concat(dangling_items(c, key))
  return Docs.Doc.Concat([Docs.Doc.Group(head), body(c, items), Docs.Doc.HardLine, text("end")])
end

def param_doc(c: Context, param: Ast.Param) -> Docs.Doc
  parts = [text("#{param.name}: "), type_doc(c, param.type)].concat(default_doc(c, param.default))
  return commented(c, Comments.key_of("Param", param.span), Docs.Doc.Concat(parts))
end

def default_doc(c: Context, value: Optional[Ast.Expr]) -> List[Docs.Doc]
  case value
    some(expr) -> return [text(" = "), expr_doc(c, expr, false)]
    none -> return []
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
  return Docs.Doc.Concat([head, body(c, items), Docs.Doc.HardLine, text("end")])
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
  return node_items(c, key, first, last_line(c, field.span), Docs.Doc.Concat(parts))
end

def enum_doc(c: Context, node: Ast.EnumDecl) -> Docs.Doc
  key = Comments.key_of("EnumDecl", node.span)
  items: List[Item] = []
  for variant in node.variants
    items = items.concat(variant_items(c, variant))
  end

  items = items.concat(dangling_items(c, key))
  head = text("enum #{node.name}#{type_parameters(node.type_parameters)}")
  return Docs.Doc.Concat([head, body(c, items), Docs.Doc.HardLine, text("end")])
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
  return node_items(c, key, first, last_line(c, variant.span), Docs.Doc.Concat(parts))
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

  return Docs.Doc.Concat(parts.concat([text(" = "), expr_doc(c, node.value, false)]))
end

def type_parameters(names: List[String]) -> String
  if names.size == 0
    return ""
  end

  return "[#{names.join(", ")}]"
end

def type_doc(c: Context, type: Ast.TypeRef) -> Docs.Doc
  doc = text(type.name)
  if type.args.size > 0
    args = type.args.map do |arg: Ast.TypeRef| type_doc(c, arg) end
    doc = Docs.Doc.Concat([doc, text("["), join(args, [text(", ")]), text("]")])
  end

  return commented(c, Comments.key_of("TypeRef", type.span), doc)
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
  items = items.push(Item(first: block.first, last: block.last, doc: Docs.Doc.Concat(lines)))
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

  return items.concat(suffixes)
end

# ---- Statements ----

def statement_items(c: Context, stmts: List[Ast.Stmt]) -> List[Item]
  items: List[Item] = []
  for stmt in stmts
    span = Ast.stmt_span(stmt)
    key = Comments.key_of(Comments.stmt_kind(stmt), span)
    items = items.concat(node_items(c, key, span.start.line, last_line(c, span), statement_doc(c, stmt)))
  end

  return items
end

def statement_doc(c: Context, stmt: Ast.Stmt) -> Docs.Doc
  case stmt
    Ast.Stmt.Binding(node) -> return binding_doc(c, node)
    Ast.Stmt.Return(node) ->
      case node.value
        some(value) -> return Docs.Doc.Concat([text("return "), expr_doc(c, value, false)])
        none -> return text("return")
      end

    Ast.Stmt.Expression(node) -> return expr_doc(c, node.value, false)
    Ast.Stmt.If(node) -> return if_doc(c, node)
    Ast.Stmt.While(node) ->
      key = Comments.key_of("WhileStmt", node.span)
      items = statement_items(c, node.body).concat(dangling_items(c, key))
      head = Docs.Doc.Concat([text("while "), expr_doc(c, node.condition, false)])
      return Docs.Doc.Concat([head, body(c, items), Docs.Doc.HardLine, text("end")])
    Ast.Stmt.For(node) ->
      key = Comments.key_of("ForStmt", node.span)
      items = statement_items(c, node.body).concat(dangling_items(c, key))
      head = Docs.Doc.Concat([text("for #{node.variable} in "), expr_doc(c, node.iterable, false)])
      return Docs.Doc.Concat([head, body(c, items), Docs.Doc.HardLine, text("end")])
    Ast.Stmt.Control(node) -> return text(node.kind)
    Ast.Stmt.Case(node) -> return case_doc(c, node)
  end
end

# `name = value`, `name: Type = value`, or a compound assignment such as `name += value`, which the parser keeps as
# `name = name + value`: the token after the name tells them apart.
def binding_doc(c: Context, node: Ast.Binding) -> Docs.Doc
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
      return Docs.Doc.Concat([text("#{node.name}: "), type_doc(c, type), text(" = "), expr_doc(c, node.value, false)])
    none -> return Docs.Doc.Concat([text("#{node.name} = "), expr_doc(c, node.value, false)])
  end
end

# `if`, its `elsif` branches and its `else`. A comment before `elsif` or `else` stays just before the keyword, at the
# indent of the `if`; a comment after `else` on its line stays there.
def if_doc(c: Context, node: Ast.IfStmt) -> Docs.Doc
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

  return Docs.Doc.Concat(parts.concat([Docs.Doc.HardLine, text("end")]))
end

# The dangling comments tagged `keyword` that start after `low` and before `high`.
def tagged(dangling: List[Comments.Attached], keyword: String, low: Int, high: Int) -> List[Comments.Attached]
  return dangling.select do |placed: Comments.Attached|
    offset = placed.comment.span.start.offset
    placed.keyword == keyword and offset > low and offset < high
  end
end

def keyword_comments(placed: List[Comments.Attached]) -> List[Docs.Doc]
  parts: List[Docs.Doc] = []
  for one in placed
    parts = parts.concat([Docs.Doc.HardLine, Docs.Doc.Comment(one.comment.text)])
  end

  return parts
end

# The dangling comments that go at the end of the last body: before `end`, or with no keyword.
def end_items(dangling: List[Comments.Attached]) -> List[Item]
  kept = dangling.select do |placed: Comments.Attached| placed.keyword == "end" or placed.keyword == "" end
  return kept.map do |placed: Comments.Attached| comment_item(placed.comment) end
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

  return found
end

def case_doc(c: Context, node: Ast.CaseStmt) -> Docs.Doc
  key = Comments.key_of("CaseStmt", node.span)
  items: List[Item] = []
  for arm in node.arms
    arm_key = Comments.key_of("CaseArm", arm.span)
    items = items.concat(node_items(c, arm_key, arm.span.start.line, last_line(c, arm.span), arm_doc(c, arm)))
  end

  items = items.concat(dangling_items(c, key))
  head = Docs.Doc.Concat([text("case "), expr_doc(c, node.value, false)])
  return Docs.Doc.Concat([head, body(c, items), Docs.Doc.HardLine, text("end")])
end

# An arm: `pattern -> statement` on one line when its body is one simple statement that fits, else the body on the
# lines below. The pattern and the guard are copied: the guard must stay on the line of its pattern.
def arm_doc(c: Context, arm: Ast.CaseArm) -> Docs.Doc
  head = source(c, tight(c, Ast.pattern_span(arm.pattern)))
  case arm.guard
    some(guard) -> head = "#{head} if #{source(c, tight(c, Ast.expr_span(guard)))}"
    none -> head = head
  end

  head = head + " ->"
  arm_key = Comments.key_of("CaseArm", arm.span)
  # The pattern and the guard are copied as text, so their comments go above the arm or after the arrow.
  keys = [Comments.key_of(Comments.pattern_kind(arm.pattern), Ast.pattern_span(arm.pattern))]
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

  if arm.body.size == 1 and simple?(arm.body[0]) and after.size == 0
    stmt = arm.body[0]
    span = Ast.stmt_span(stmt)
    key = Comments.key_of(Comments.stmt_kind(stmt), span)
    found = around(c, key)
    if found.before.size == 0 and c.trailing.get(key, []).all? do |comment: Tokens.Comment| !comment.own_line end
      suffixes = c.trailing.get(key, []).map do |comment: Tokens.Comment| Docs.Doc.LineSuffix(" " + comment.text) end
      line = Docs.Doc.Group([text(head), Docs.Doc.Indent([Docs.Doc.Line, statement_doc(c, stmt)])])
      return Docs.Doc.Concat(above.push(line).concat(suffixes).concat(dangling_end(c, arm_key)))
    end
  end

  items = statement_items(c, arm.body).concat(dangling_items(c, arm_key))
  return Docs.Doc.Concat(above.push(text(head)).concat(after).push(body(c, items)))
end

def dangling_end(c: Context, key: String) -> List[Docs.Doc]
  items = dangling_items(c, key)
  if items.size == 0
    return []
  end

  return [Docs.Doc.Indent([Docs.Doc.HardLine, sequence(c, items)])]
end

def simple?(stmt: Ast.Stmt) -> Bool
  case stmt
    Ast.Stmt.Binding(_) -> return true
    Ast.Stmt.Return(_) -> return true
    Ast.Stmt.Expression(_) -> return true
    Ast.Stmt.Control(_) -> return true
    _ -> return false
  end
end

# ---- Expressions ----

# An expression with its comments. `bracketed` says that it sits directly inside brackets (an argument, an element, an
# entry or an operand of a broken expression), where a line break needs no parentheses of its own.
def expr_doc(c: Context, expr: Ast.Expr, bracketed: Bool) -> Docs.Doc
  key = Comments.key_of(Comments.expr_kind(expr), Ast.expr_span(expr))
  return commented(c, key, bare(c, expr, bracketed))
end

def bare(c: Context, expr: Ast.Expr, bracketed: Bool) -> Docs.Doc
  case expr
    Ast.Expr.Literal(node) -> return lone(literal(c, node.span), node.span, c, bracketed)
    Ast.Expr.Name(node) -> return text(node.name)
    Ast.Expr.Call(node) ->
      if node.piped
        return pipe_doc(c, expr, bracketed)
      end

      return call_doc(c, node)
    Ast.Expr.EnumConstructor(node) ->
      name = text("#{node.enum_name}.#{node.variant_name}")
      if node.args.size == 0 and not source(c, node.span).ends_with?(")")
        return name
      end

      return Docs.Doc.Concat([name, arguments(c, node.args, Comments.key_of("EnumConstructor", node.span))])
    Ast.Expr.FunctionRef(node) -> return text("&#{node.name}")
    Ast.Expr.Construct(node) ->
      named = node.args.map do |arg: Ast.NamedArg| named_doc(c, arg) end
      dangling = dangling_comments(c, Comments.key_of("Construct", node.span))
      return listed(text("#{node.type_name}("), named, text(")"), dangling)
    Ast.Expr.ListLit(node) ->
      elements = node.elements.map do |element: Ast.Expr| expr_doc(c, element, true) end
      starts = node.elements.map do |element: Ast.Expr| Ast.expr_span(element).start.line end
      packed = shared_line?(starts) and node.elements.all? do |element: Ast.Expr| atomic?(c, element) end
      dangling = dangling_comments(c, Comments.key_of("ListLit", node.span))
      return packed_list(text("["), elements, text("]"), dangling, packed)
    Ast.Expr.MapLit(node) ->
      entries = node.entries.map do |entry: Ast.MapEntry| entry_doc(c, entry) end
      starts = node.entries.map do |entry: Ast.MapEntry| entry.span.start.line end
      packed = shared_line?(starts) and node.entries.all? do |entry: Ast.MapEntry| atomic_entry?(c, entry) end
      dangling = dangling_comments(c, Comments.key_of("MapLit", node.span))
      return packed_list(text("{"), entries, text("}"), dangling, packed)
    Ast.Expr.Interpolation(node) -> return lone(literal(c, node.span), node.span, c, bracketed)
    Ast.Expr.BlockLit(node) -> return block_doc(c, node)
    Ast.Expr.Try(node) ->
      if piped?(node.operand)
        return pipe_doc(c, expr, bracketed)
      end

      return Docs.Doc.Concat([text("try "), operand(c, node.operand, UNARY_LEVEL)])
    Ast.Expr.Unary(node) ->
      operator = source(c, node.op_span)
      if operator.length > 1
        operator = operator + " "
      end

      return Docs.Doc.Concat([text(operator), operand(c, node.operand, UNARY_LEVEL)])
    Ast.Expr.Binary(node) -> return binary_doc(c, node, bracketed)
    Ast.Expr.TypeName(node) -> return text(node.name)
    Ast.Expr.MethodCall(_) -> return chain_doc(c, expr, bracketed)
    Ast.Expr.FieldAccess(_) -> return chain_doc(c, expr, bracketed)
    Ast.Expr.Invoke(_) -> return chain_doc(c, expr, bracketed)
    Ast.Expr.Update(_) -> return chain_doc(c, expr, bracketed)
    Ast.Expr.Index(_) -> return chain_doc(c, expr, bracketed)
    _ -> return text(source(c, Ast.expr_span(expr)))
  end
end

# Whether an element is a short atom that a table packs: a literal, a name, a negative number or a variant without
# arguments, with no comment.
def atomic?(c: Context, expr: Ast.Expr) -> Bool
  key = Comments.key_of(Comments.expr_kind(expr), Ast.expr_span(expr))
  if c.leading.get(key, []).size > 0 or c.trailing.get(key, []).size > 0
    return false
  end

  case expr
    Ast.Expr.Literal(node) -> return not source(c, node.span).starts_with?("<<~")
    Ast.Expr.Name(_) -> return true
    Ast.Expr.TypeName(_) -> return true
    Ast.Expr.FunctionRef(_) -> return true
    Ast.Expr.Unary(node) -> return atomic?(c, node.operand)
    Ast.Expr.EnumConstructor(node) -> return node.args.size == 0
    _ -> return false
  end
end

# Whether two items start on one line: a table the author packed, which stays packed.
def shared_line?(starts: List[Int]) -> Bool
  at = 1
  while at < starts.size
    if starts[at] == starts[at - 1]
      return true
    end

    at += 1
  end

  return false
end

def atomic_entry?(c: Context, entry: Ast.MapEntry) -> Bool
  key = Comments.key_of("MapEntry", entry.span)
  quiet = c.leading.get(key, []).size == 0 and c.trailing.get(key, []).size == 0
  return quiet and atomic?(c, entry.key) and atomic?(c, entry.value)
end

# A literal as written. A heredoc keeps its opener here and its body after the line.
def literal(c: Context, span: Source.Span) -> Docs.Doc
  written = source(c, span)
  if written.starts_with?("<<~")
    return Docs.Doc.Concat([text(written), Docs.Doc.After(c.heredocs.get(span.start.offset, []))])
  end

  return text(written)
end

# A string that cannot break, outside brackets: on the next line in parentheses when it does not fit after what comes
# before it, as the repo writes a long message.
def lone(doc: Docs.Doc, span: Source.Span, c: Context, bracketed: Bool) -> Docs.Doc
  if bracketed or source(c, span).starts_with?("<<~")
    return doc
  end

  return wrapped([doc], false)
end

# The level of an expression, for the parentheses: a binary operator's, a range's (0), a pipe's, a prefix's or a
# postfix or primary expression's.
def level(expr: Ast.Expr) -> Int
  case expr
    Ast.Expr.Binary(node) -> return LEVELS.get(node.op, 0)
    Ast.Expr.Call(node) ->
      if node.piped
        return PIPE_LEVEL
      end

      return POSTFIX_LEVEL
    Ast.Expr.Try(node) ->
      if piped?(node.operand)
        return PIPE_LEVEL
      end

      return UNARY_LEVEL
    Ast.Expr.Unary(_) -> return UNARY_LEVEL
    _ -> return POSTFIX_LEVEL
  end
end

def piped?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Call(node) -> return node.piped
    _ -> return false
  end
end

# Whether an operand of `op` keeps parentheses that the precedence does not need, for the reader: an `and` inside an
# `or`, and a `*`, `/` or `%` inside another of them.
def clarify?(op: String, child: Ast.Expr) -> Bool
  case child
    Ast.Expr.Binary(node) ->
      if op == "or" and node.op == "and"
        return true
      end

      return LEVELS.get(op, 0) == 7 and LEVELS.get(node.op, 0) == 7 and op != node.op
    _ -> return false
  end
end

def binary?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Binary(_) -> return true
    _ -> return false
  end
end

# An operand in parentheses when it is looser than `minimum` or when `force` asks for them.
def clear(c: Context, expr: Ast.Expr, minimum: Int, force: Bool) -> Docs.Doc
  if force
    return operand(c, expr, POSTFIX_LEVEL + 1)
  end

  return operand(c, expr, minimum)
end

# An operand that needs the level `minimum`: in parentheses when it is looser. Inside them, or inside the operator's
# own broken form, a line break needs no more parentheses.
def operand(c: Context, expr: Ast.Expr, minimum: Int) -> Docs.Doc
  if level(expr) >= minimum
    return expr_doc(c, expr, true)
  end

  return Docs.Doc.Group([
    text("("),
    Docs.Doc.Indent([Docs.Doc.SoftLine, expr_doc(c, expr, true)]),
    Docs.Doc.SoftLine,
    text(")"),
  ])
end

# A broken expression: as it is inside brackets, else in parentheses of its own that only a broken layout shows,
# with its lines two spaces deeper.
def wrapped(parts: List[Docs.Doc], bracketed: Bool) -> Docs.Doc
  if bracketed
    return Docs.Doc.Group(parts)
  end

  return Docs.Doc.Group([
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

  return wrapped([first].concat(parts), bracketed)
end

# A pipe chain, `x |> f() |> g()`, with each `|>` at the start of its line when it breaks, as the repo writes it.
def pipe_doc(c: Context, expr: Ast.Expr, bracketed: Bool) -> Docs.Doc
  stages: List[Docs.Doc] = []
  current = expr
  looping = true
  while looping
    looping = false
    key = Comments.key_of(Comments.expr_kind(current), Ast.expr_span(current))
    case current
      Ast.Expr.Call(node) ->
        if node.piped
          stage = Docs.Doc.Concat([text("|> "), call_doc(c, node.with(args: node.args.drop(1), parenthesized: true))])
          if stages.size > 0
            stage = commented(c, key, stage)
          end

          stages = List.concat([stage], stages)
          current = node.args[0]
          looping = true
        end

      Ast.Expr.Try(node) ->
        case node.operand
          Ast.Expr.Call(call) ->
            if call.piped
              shown = call_doc(c, call.with(args: call.args.drop(1), parenthesized: true))
              stage = Docs.Doc.Concat([text("|> try "), shown])
              if stages.size > 0
                stage = commented(c, key, stage)
              end

              stages = List.concat([stage], stages)
              current = call.args[0]
              looping = true
            end

          _ -> looping = false
        end

      _ -> looping = false
    end
  end

  parts: List[Docs.Doc] = [operand(c, current, PIPE_LEVEL)]
  for stage in stages
    parts = parts.concat([Docs.Doc.Line, stage])
  end

  return wrapped(parts, bracketed)
end

# A call by name: `f(args)`, `puts x` without parentheses, and a trailing `do` block.
def call_doc(c: Context, node: Ast.Call) -> Docs.Doc
  args = node.args
  block: List[Docs.Doc] = []
  if args.size > 0
    case args[args.size - 1]
      Ast.Expr.BlockLit(lit) ->
        block = [text(" "), expr_doc(c, args[args.size - 1], false)]
        args = args.take(args.size - 1)
      _ -> block = block
    end
  end

  if node.parenthesized
    return Docs.Doc.Concat([text(node.name), arguments(c, args, Comments.key_of("Call", node.span))].concat(block))
  end

  if args.size == 0
    return Docs.Doc.Concat([text(node.name)].concat(block))
  end

  shown = args.map do |arg: Ast.Expr| expr_doc(c, arg, true) end
  return Docs.Doc.Concat([text(node.name + " "), join(shown, [text(", ")])].concat(block))
end

# The arguments of a call. A sole argument that is a list or map literal hugs the parentheses, `Set.new([`, and
# breaks inside its own brackets.
def arguments(c: Context, args: List[Ast.Expr], key: String) -> Docs.Doc
  shown = args.map do |arg: Ast.Expr| expr_doc(c, arg, true) end
  if args.size == 1 and huggable?(c, args[0])
    return Docs.Doc.Concat([text("("), shown[0], text(")")])
  end

  return listed(text("("), shown, text(")"), dangling_comments(c, key))
end

def huggable?(c: Context, expr: Ast.Expr) -> Bool
  key = Comments.key_of(Comments.expr_kind(expr), Ast.expr_span(expr))
  if c.leading.get(key, []).size > 0 or c.trailing.get(key, []).size > 0
    return false
  end

  case expr
    Ast.Expr.ListLit(node) -> return node.elements.size > 0
    Ast.Expr.MapLit(node) -> return node.entries.size > 0
    _ -> return false
  end
end

def named_doc(c: Context, arg: Ast.NamedArg) -> Docs.Doc
  doc = Docs.Doc.Concat([text("#{arg.name}: "), expr_doc(c, arg.value, false)])
  return commented(c, Comments.key_of("NamedArg", arg.span), doc)
end

def entry_doc(c: Context, entry: Ast.MapEntry) -> Docs.Doc
  doc = Docs.Doc.Concat([expr_doc(c, entry.key, true), text(": "), expr_doc(c, entry.value, false)])
  return commented(c, Comments.key_of("MapEntry", entry.span), doc)
end

# A method chain: the receiver, then each `.name(args)`, `.name`, `.call(args)`, `.with(...)` or `[index]`. A chain
# with two calls or more breaks before each `.` when it does not fit (47.5 rule 10): the first call stays with a
# receiver that is a plain name.
def chain_doc(c: Context, expr: Ast.Expr, bracketed: Bool) -> Docs.Doc
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

  return wrapped(start.push(Docs.Doc.Indent(rest)), bracketed)
end

def link_of(c: Context, expr: Ast.Expr) -> Optional[Link]
  case expr
    Ast.Expr.MethodCall(node) -> return some(method_link(c, node))
    Ast.Expr.FieldAccess(node) -> return some(Link(doc: text(".#{node.name}"), block: [], call: false, breaks: true))
    Ast.Expr.Invoke(node) ->
      shown = Docs.Doc.Concat([text(".call"), arguments(c, node.args, Comments.key_of("Invoke", node.span))])
      return some(Link(doc: shown, block: [], call: true, breaks: true))
    Ast.Expr.Update(node) ->
      named = node.args.map do |arg: Ast.NamedArg| named_doc(c, arg) end
      return some(Link(doc: listed(text(".with("), named, text(")"), []), block: [], call: true, breaks: true))
    Ast.Expr.Index(node) ->
      inner = Docs.Doc.Group([
        text("["),
        Docs.Doc.Indent([Docs.Doc.SoftLine, expr_doc(c, node.index, true)]),
        Docs.Doc.SoftLine,
        text("]"),
      ])
      return some(Link(doc: inner, block: [], call: false, breaks: false))
    _ -> return none
  end
end

def target_of(expr: Ast.Expr) -> Ast.Expr
  case expr
    Ast.Expr.MethodCall(node) -> return node.target
    Ast.Expr.FieldAccess(node) -> return node.target
    Ast.Expr.Invoke(node) -> return node.target
    Ast.Expr.Update(node) -> return node.target
    Ast.Expr.Index(node) -> return node.target
    _ -> return expr
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
  return Link(doc: shown, block: block, call: true, breaks: true)
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
  if quiet and node.body.size == 1 and simple?(node.body[0]) and c.dangling.get(key, []).size == 0
    stmt = node.body[0]
    stmt_key = Comments.key_of(Comments.stmt_kind(stmt), Ast.stmt_span(stmt))
    if c.leading.get(stmt_key, []).size == 0 and c.trailing.get(stmt_key, []).size == 0
      return Docs.Doc.Group([
        text(head),
        Docs.Doc.Indent([Docs.Doc.Line, statement_doc(c, stmt)]),
        Docs.Doc.Line,
        text("end"),
      ])
    end
  end

  # A body on its own lines breaks every group around the block, so the items next to it go on lines of their own.
  items = above.concat(statement_items(c, node.body)).concat(dangling_items(c, key))
  parts = [Docs.Doc.BreakParent, text(head)].concat(suffixes)
  return Docs.Doc.Concat(parts.concat([body(c, items), Docs.Doc.HardLine, text("end")]))
end

# Whether a document starts with the break of a multi-line block body (`block_doc`).
def broken?(doc: Docs.Doc) -> Bool
  case doc
    Docs.Doc.BreakParent -> return true
    Docs.Doc.Concat(parts) -> return parts.size > 0 and broken?(parts[0])
    _ -> return false
  end
end

# The document without the break it starts with.
def unbroken(doc: Docs.Doc) -> Docs.Doc
  case doc
    Docs.Doc.BreakParent -> return Docs.Doc.Concat([])
    Docs.Doc.Concat(parts) ->
      if parts.size == 0
        return doc
      end

      return Docs.Doc.Concat([unbroken(parts[0])].concat(parts.drop(1)))
    _ -> return doc
  end
end

# A block parameter as text; it has no layout of its own.
def block_param(c: Context, param: Ast.BlockParam) -> String
  case param.type
    some(type) -> return "#{param.name}: #{type_text(type)}"
    none -> return param.name
  end
end

def type_text(type: Ast.TypeRef) -> String
  if type.args.size == 0
    return type.name
  end

  return "#{type.name}[#{type.args.map do |arg: Ast.TypeRef| type_text(arg) end.join(", ")}]"
end

# The dangling comments of an empty list, call or literal.
def dangling_comments(c: Context, key: String) -> List[Tokens.Comment]
  return c.dangling.get(key, []).map do |placed: Comments.Attached| placed.comment end
end

# Items between brackets: on one line when they fit, else one per line, two spaces deeper, with a trailing comma
# (47.5 rules 2 and 14). An empty list keeps its dangling comments inside, each on its own line.
def listed(open: Docs.Doc, items: List[Docs.Doc], close: Docs.Doc, dangling: List[Tokens.Comment]) -> Docs.Doc
  return packed_list(open, items, close, dangling, false)
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
    if dangling.size == 0
      return Docs.Doc.Concat([open, close])
    end

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
  return Docs.Doc.Group([open, Docs.Doc.Indent(inner), Docs.Doc.SoftLine, close])
end

# ---- Helpers ----

def text(value: String) -> Docs.Doc
  return Docs.Doc.Text(value)
end

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

  return Docs.Doc.Concat(parts)
end

# A node the parser made without text of its own has an empty span.
def written?(span: Source.Span) -> Bool
  return span.stop.offset > span.start.offset
end

# The source text of a span.
def source(c: Context, span: Source.Span) -> String
  first = span.start.line
  last = span.stop.line
  if first == last
    return c.lines[first - 1].slice(span.start.column - 1, span.stop.column - span.start.column)
  end

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

  return parts.join("\n")
end

# The span cut at its last token.
def tight(c: Context, span: Source.Span) -> Source.Span
  at = token_index(c, span.stop.offset) - 1
  while at >= 0 and c.tokens[at].span.stop.offset > span.stop.offset
    at -= 1
  end

  if at < 0 or c.tokens[at].span.stop.offset <= span.start.offset
    return span
  end

  return span.with(stop: c.tokens[at].span.stop)
end

# The line of the last token of a span.
def last_line(c: Context, span: Source.Span) -> Int
  return tight(c, span).stop.line
end

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

  return low
end

def trim_end(line: String) -> String
  stop = line.length
  while stop > 0 and (line.slice(stop - 1, 1) == " " or line.slice(stop - 1, 1) == "\t")
    stop -= 1
  end

  return line.slice(0, stop)
end

def decl_span(decl: Ast.Decl) -> Source.Span
  case decl
    Ast.Decl.Import(node) -> return node.span
    Ast.Decl.Reexport(node) -> return node.span
    Ast.Decl.Export(node) -> return node.span
    Ast.Decl.Function(node) -> return node.span
    Ast.Decl.Struct(node) -> return node.span
    Ast.Decl.Enum(node) -> return node.span
    Ast.Decl.TypeAlias(node) -> return node.span
    Ast.Decl.Resource(node) -> return node.span
    Ast.Decl.Constant(node) -> return node.span
  end
end

# ---- Docs, heredocs and extern blocks in the source ----

# The first line of the `##` block right above the line of `offset`'s node.
def doc_first(c: Context, offset: Int) -> Int
  at = token_index(c, offset) - 1
  if at >= 0 and c.tokens[at].kind == "DOC"
    return c.tokens[at].span.start.line
  end

  # A doc without its token cannot happen; keep the node's own line.
  at = token_index(c, offset)
  return c.tokens[at].span.start.line
end

# The last line of the `##` block that starts at `first`.
def doc_last(c: Context, first: Int) -> Int
  last = first
  while last < c.lines.size and c.lines[last].strip.starts_with?("##")
    last += 1
  end

  return last
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

  return parts
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

  return bodies
end

def heredoc_name(opener: String) -> String
  at = 3
  while at < opener.length and "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_".contains?(opener.slice(at, 1))
    at += 1
  end

  return opener.slice(3, at - 3)
end

# The `extern` blocks: from a top-level `extern` followed by a string to the first line that is `end` at the left
# margin.
def extern_blocks(lines: List[String], tokens: List[Tokens.Token]) -> List[Extern]
  blocks: List[Extern] = []
  at = 0
  while at + 1 < tokens.size
    token = tokens[at]
    next = tokens[at + 1].kind
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

  return blocks
end

# The index of the extern block that holds `offset`, or -1.
def extern_at(blocks: List[Extern], offset: Int) -> Int
  at = 0
  while at < blocks.size
    if blocks[at].start <= offset and offset < blocks[at].stop
      return at
    end

    at += 1
  end

  return -1
end
