## The plain comments of a file attached to its tree (docs/future/47-formatter.md, 47.4), the first step of the
## formatter. The lexer keeps the comments in a side list (`Lexer.lex_with_comments`), so the tree, the checker and
## the later stages never see them; this pass gives each comment one node and one role, before any layout.
##
## The nodes are an outline of the tree: one entry per node with a span (declarations, parameters, fields, variants,
## types, statements, `if` branches, `case` arms, patterns, expressions, named arguments, map entries, block
## parameters and import names), plus the module doc, which the tree keeps as text only. Each has the kind of its
## tree node and its span cut at its last token that is not a line break, because a parsed span can end with the line
## break after the node. The outline is built with a worklist and no recursion, so a deep tree cannot reach the limit
## of VM calls.
##
## The rules, after Prettier and syntax_tree: for each comment, the enclosing node is the deepest node whose span holds
## it, and the preceding and following nodes are the closest children of that node before and after it. A comment
## alone on its line leads the following node, else trails the preceding one; a comment after code trails the
## preceding node, else leads the following one; with neither it dangles on the enclosing node. The positions where
## that is wrong are fixed by keyword, read from the tokens, since `elsif`, `else`, `end` and a chain's `.` have no
## node: see `place`.

import Ast from "../syntax/ast"
import Source from "../syntax/source"
import Tokens from "../syntax/token"

# The kinds of the statement nodes.
STATEMENT_KINDS = Set.new(
  ["Binding", "Return", "ExprStmt", "IfStmt", "WhileStmt", "ForStmt", "LoopControl", "CaseStmt"],
)
# The nodes a comment before `end` trails: a statement, or a field or variant before the `end` of its declaration.
BODY_END_KINDS = STATEMENT_KINDS.union(Set.new(["FieldDecl", "EnumVariant"]))

## A node of the outline: the name of its tree node (`FunctionDecl`, `Param`, `IfStmt`, `Call`, ... and `ModuleDoc`
## for the module doc), its span from its first token to its last token that is not a line break, and the index of
## its parent in the outline (-1 for the Program, which is always the first entry).
export struct Node
  kind: String
  span: Source.Span
  parent: Int
end

## A comment and its place: the index of its node in the outline, its role, and the keyword a dangling comment comes
## before or after when that keyword has no node (`elsif`, `else` or `end`; "" otherwise).
export struct Attached
  comment: Tokens.Comment
  node: Int
  role: Role
  keyword: String
end

## The outline of a file and its comments in source order, each with its place.
export struct Attachment
  nodes: List[Node]
  comments: List[Attached]
end

# A part waiting in the worklist, with the index of its parent.
struct Pending
  part: Part
  parent: Int
end

# The outline with, for each node, where its children start in it and how many there are: a node's children are
# queued together, so they sit side by side.
struct Outline
  nodes: List[Node]
  first: List[Int]
  count: List[Int]
end

# The tokens that are not line breaks or the end of the text, with their offsets for the binary searches.
struct Marks
  tokens: List[Tokens.Token]
  starts: List[Int]
  stops: List[Int]
end

## How a comment sits on its node: above it (`Leading`), after it (`Trailing`), or inside a node that has no child at
## that place (`Dangling`), such as an empty body or list.
export enum Role
  Leading
  Trailing
  Dangling
end

# A part of the tree that can be a node of the outline.
enum Part
  Program(Ast.Program)
  ModuleDoc(Tokens.Token)
  Decl(Ast.Decl)
  ImportName(Ast.ImportName)
  Param(Ast.Param)
  Field(Ast.FieldDecl)
  Variant(Ast.EnumVariant)
  Type(Ast.TypeRef)
  Stmt(Ast.Stmt)
  Branch(Ast.IfBranch)
  Arm(Ast.CaseArm)
  Pattern(Ast.Pattern)
  Expr(Ast.Expr)
  Named(Ast.NamedArg)
  Entry(Ast.MapEntry)
  BlockParam(Ast.BlockParam)
end

## Attaches each comment of `comments` to a node of `program`, which was parsed from `tokens`.
export def attach(program: Ast.Program, tokens: List[Tokens.Token], comments: List[Tokens.Comment]) -> Attachment
  marks = marks_of(tokens)
  outline = outline_of(program, marks)
  placed = comments.map do |comment: Tokens.Comment| place(outline, marks, comment) end
  return Attachment(nodes: outline.nodes, comments: placed)
end

## The name of a role, as the text form prints it.
export def role_name(role: Role) -> String
  case role
    Role.Leading -> return "leading"
    Role.Trailing -> return "trailing"
    Role.Dangling -> return "dangling"
  end
end

def marks_of(tokens: List[Tokens.Token]) -> Marks
  kept = tokens.select do |token: Tokens.Token| token.kind != "NL" and token.kind != "EOF" end
  starts = kept.map do |token: Tokens.Token| token.span.start.offset end
  stops = kept.map do |token: Tokens.Token| token.span.stop.offset end
  return Marks(tokens: kept, starts: starts, stops: stops)
end

# The outline, breadth first: the parts of the queue are the nodes, in queue order.
def outline_of(program: Ast.Program, marks: Marks) -> Outline
  queue: List[Pending] = [Pending(part: Part.Program(program), parent: -1)]
  nodes: List[Node] = []
  first: List[Int] = []
  count: List[Int] = []
  at = 0
  while at < queue.size
    pending = queue[at]
    span = tight(span_of(pending.part), marks)
    nodes = nodes.push(Node(kind: kind_of(pending.part), span: span, parent: pending.parent))
    children = children_of(pending.part, marks).select do |part: Part| written?(span_of(part)) end
    first = first.push(queue.size)
    count = count.push(children.size)
    for child in children
      queue = queue.push(Pending(part: child, parent: at))
    end

    at += 1
  end

  return Outline(nodes: nodes, first: first, count: count)
end

# A node the parser made without text of its own has an empty span; it gets no comment.
def written?(span: Source.Span) -> Bool
  return span.stop.offset > span.start.offset
end

# The span cut at its last token that is not a line break.
def tight(span: Source.Span, marks: Marks) -> Source.Span
  last = last_at_or_before(marks.stops, span.stop.offset)
  if last < 0 or marks.stops[last] <= span.start.offset
    return span
  end

  return span.with(stop: marks.tokens[last].span.stop)
end

# The index of the last value of the ascending `values` that is at most `limit`, or -1.
def last_at_or_before(values: List[Int], limit: Int) -> Int
  low = 0
  high = values.size
  while low < high
    middle = (low + high) / 2
    if values[middle] <= limit
      low = middle + 1
    else
      high = middle
    end
  end

  return low - 1
end

# The index of the first value of the ascending `values` that is at least `limit`, or the size of the list.
def first_at_or_after(values: List[Int], limit: Int) -> Int
  low = 0
  high = values.size
  while low < high
    middle = (low + high) / 2
    if values[middle] < limit
      low = middle + 1
    else
      high = middle
    end
  end

  return low
end

# Where one comment goes. The keyword rules come first: `prior` and `upcoming` are the kinds of the tokens around the
# comment ("" at either end of the text).
def place(outline: Outline, marks: Marks, comment: Tokens.Comment) -> Attached
  start = comment.span.start.offset
  before = last_at_or_before(marks.stops, start)
  after = first_at_or_after(marks.starts, comment.span.stop.offset)
  prior = token_kind(marks, before)
  upcoming = token_kind(marks, after)
  enclosing = enclosing_of(outline, start)
  preceding = preceding_of(outline, enclosing, start)
  following = following_of(outline, enclosing, comment.span.stop.offset)
  is_if = outline.nodes[enclosing].kind == "IfStmt"
  # After `else`: on the same line, or alone with an empty `else` body; the comment goes after the keyword.
  if is_if and prior == "else" and (not comment.own_line or upcoming == "end")
    return Attached(comment: comment, node: enclosing, role: Role.Dangling, keyword: "else")
  end

  if comment.own_line
    # Before `elsif` or `else`: just before the keyword, at the indent of the `if`.
    if is_if and (upcoming == "elsif" or upcoming == "else")
      return Attached(comment: comment, node: enclosing, role: Role.Dangling, keyword: upcoming)
    end

    # Before `end`: after the last statement of the last body, or the last field or variant, else alone in an empty
    # body (what comes before it is a parameter, a type or a condition).
    if upcoming == "end"
      last = last_statement(outline, preceding)
      if last >= 0 and BODY_END_KINDS.include?(outline.nodes[last].kind)
        return Attached(comment: comment, node: last, role: Role.Trailing, keyword: "")
      end

      return Attached(comment: comment, node: enclosing, role: Role.Dangling, keyword: "end")
    end

    # Between the lines of a method chain: after the call before it.
    if upcoming == "dot" and preceding >= 0
      return Attached(comment: comment, node: preceding, role: Role.Trailing, keyword: "")
    end

    # After the module doc, before the first declaration: it stays with the doc.
    if preceding >= 0 and outline.nodes[preceding].kind == "ModuleDoc"
      return Attached(comment: comment, node: preceding, role: Role.Trailing, keyword: "")
    end

    return by_order(comment, enclosing, following, preceding, Role.Leading, Role.Trailing)
  end

  return by_order(comment, enclosing, preceding, following, Role.Trailing, Role.Leading)
end

# The first of `first` and `second` that exists, with its role; else dangling on `enclosing`.
def by_order(
  comment: Tokens.Comment,
  enclosing: Int,
  first: Int,
  second: Int,
  first_role: Role,
  second_role: Role,
) -> Attached
  if first >= 0
    return Attached(comment: comment, node: first, role: first_role, keyword: "")
  end

  if second >= 0
    return Attached(comment: comment, node: second, role: second_role, keyword: "")
  end

  return Attached(comment: comment, node: enclosing, role: Role.Dangling, keyword: "")
end

def token_kind(marks: Marks, index: Int) -> String
  if index < 0 or index >= marks.tokens.size
    return ""
  end

  return marks.tokens[index].kind
end

# The deepest node whose span holds `offset`, found from the Program down; the Program when no node holds it.
def enclosing_of(outline: Outline, offset: Int) -> Int
  current = 0
  looking = true
  while looking
    looking = false
    child = outline.first[current]
    stop = child + outline.count[current]
    while child < stop
      if holds?(outline.nodes[child].span, offset)
        current = child
        looking = true
        child = stop
      else
        child += 1
      end
    end
  end

  return current
end

def holds?(span: Source.Span, offset: Int) -> Bool
  return span.start.offset <= offset and offset < span.stop.offset
end

# The child of `parent` that ends last at or before `offset`, or -1.
def preceding_of(outline: Outline, parent: Int, offset: Int) -> Int
  found = -1
  child = outline.first[parent]
  stop = child + outline.count[parent]
  while child < stop
    span = outline.nodes[child].span
    if span.stop.offset <= offset and (found < 0 or span.stop.offset >= outline.nodes[found].span.stop.offset)
      found = child
    end

    child += 1
  end

  return found
end

# The child of `parent` that starts first at or after `offset`, or -1.
def following_of(outline: Outline, parent: Int, offset: Int) -> Int
  found = -1
  child = outline.first[parent]
  stop = child + outline.count[parent]
  while child < stop
    span = outline.nodes[child].span
    if span.start.offset >= offset and (found < 0 or span.start.offset < outline.nodes[found].span.start.offset)
      found = child
    end

    child += 1
  end

  return found
end

# The last statement before an `end`: `node` itself, or for an `if` branch or a `case` arm the last statement of its
# body; -1 when there is none (no node, or an empty body).
def last_statement(outline: Outline, node: Int) -> Int
  if node < 0
    return -1
  end

  kind = outline.nodes[node].kind
  if kind != "IfBranch" and kind != "CaseArm"
    return node
  end

  last = preceding_of(outline, node, outline.nodes[node].span.stop.offset)
  if last >= 0 and statement?(outline.nodes[last].kind)
    return last
  end

  return -1
end

def statement?(kind: String) -> Bool
  return STATEMENT_KINDS.include?(kind)
end

def span_of(part: Part) -> Source.Span
  case part
    Part.Program(node) -> return node.span
    Part.ModuleDoc(token) -> return token.span
    Part.Decl(decl) -> return decl_span(decl)
    Part.ImportName(node) -> return node.span
    Part.Param(node) -> return node.span
    Part.Field(node) -> return node.span
    Part.Variant(node) -> return node.span
    Part.Type(node) -> return node.span
    Part.Stmt(stmt) -> return Ast.stmt_span(stmt)
    Part.Branch(node) -> return node.span
    Part.Arm(node) -> return node.span
    Part.Pattern(pattern) -> return Ast.pattern_span(pattern)
    Part.Expr(expr) -> return Ast.expr_span(expr)
    Part.Named(node) -> return node.span
    Part.Entry(node) -> return node.span
    Part.BlockParam(node) -> return node.span
  end
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

def kind_of(part: Part) -> String
  case part
    Part.Program(_) -> return "Program"
    Part.ModuleDoc(_) -> return "ModuleDoc"
    Part.Decl(decl) -> return decl_kind(decl)
    Part.ImportName(_) -> return "ImportName"
    Part.Param(_) -> return "Param"
    Part.Field(_) -> return "FieldDecl"
    Part.Variant(_) -> return "EnumVariant"
    Part.Type(_) -> return "TypeRef"
    Part.Stmt(stmt) -> return stmt_kind(stmt)
    Part.Branch(_) -> return "IfBranch"
    Part.Arm(_) -> return "CaseArm"
    Part.Pattern(pattern) -> return pattern_kind(pattern)
    Part.Expr(expr) -> return expr_kind(expr)
    Part.Named(_) -> return "NamedArg"
    Part.Entry(_) -> return "MapEntry"
    Part.BlockParam(_) -> return "BlockParam"
  end
end

def decl_kind(decl: Ast.Decl) -> String
  case decl
    Ast.Decl.Import(_) -> return "ImportDecl"
    Ast.Decl.Reexport(_) -> return "ReexportDecl"
    Ast.Decl.Export(_) -> return "ExportDecl"
    Ast.Decl.Function(_) -> return "FunctionDecl"
    Ast.Decl.Struct(_) -> return "StructDecl"
    Ast.Decl.Enum(_) -> return "EnumDecl"
    Ast.Decl.TypeAlias(_) -> return "TypeAliasDecl"
    Ast.Decl.Resource(_) -> return "ResourceDecl"
    Ast.Decl.Constant(_) -> return "ConstDecl"
  end
end

def stmt_kind(stmt: Ast.Stmt) -> String
  case stmt
    Ast.Stmt.Binding(_) -> return "Binding"
    Ast.Stmt.Return(_) -> return "Return"
    Ast.Stmt.Expression(_) -> return "ExprStmt"
    Ast.Stmt.If(_) -> return "IfStmt"
    Ast.Stmt.While(_) -> return "WhileStmt"
    Ast.Stmt.For(_) -> return "ForStmt"
    Ast.Stmt.Control(_) -> return "LoopControl"
    Ast.Stmt.Case(_) -> return "CaseStmt"
  end
end

def pattern_kind(pattern: Ast.Pattern) -> String
  case pattern
    Ast.Pattern.Wildcard(_) -> return "WildcardPattern"
    Ast.Pattern.Literal(_) -> return "LiteralPattern"
    Ast.Pattern.Variant(_) -> return "VariantPattern"
  end
end

def expr_kind(expr: Ast.Expr) -> String
  case expr
    Ast.Expr.Literal(_) -> return "Literal"
    Ast.Expr.Name(_) -> return "NameRef"
    Ast.Expr.Call(_) -> return "Call"
    Ast.Expr.EnumConstructor(_) -> return "EnumConstructor"
    Ast.Expr.FunctionRef(_) -> return "FunctionRef"
    Ast.Expr.Invoke(_) -> return "Invoke"
    Ast.Expr.Construct(_) -> return "Construct"
    Ast.Expr.Update(_) -> return "StructUpdate"
    Ast.Expr.ListLit(_) -> return "ListLit"
    Ast.Expr.MapLit(_) -> return "MapLit"
    Ast.Expr.FieldAccess(_) -> return "FieldAccess"
    Ast.Expr.MethodCall(_) -> return "MethodCall"
    Ast.Expr.Interpolation(_) -> return "Interpolation"
    Ast.Expr.BlockLit(_) -> return "BlockLit"
    Ast.Expr.Index(_) -> return "IndexAccess"
    Ast.Expr.Try(_) -> return "TryExpr"
    Ast.Expr.Unary(_) -> return "Unary"
    Ast.Expr.Binary(_) -> return "Binary"
    Ast.Expr.TypeName(_) -> return "TypeName"
    Ast.Expr.Typed(_) -> return "TypedTarget"
    Ast.Expr.ConstRef(_) -> return "ConstRef"
  end
end

# The children of a part, in source order.
def children_of(part: Part, marks: Marks) -> List[Part]
  case part
    Part.Program(node) -> return module_doc(node, marks).concat(decls(node.declarations))
    Part.Decl(decl) -> return decl_children(decl)
    Part.Param(node) -> return [Part.Type(node.type)].concat(optional_expr(node.default))
    Part.Field(node) -> return [Part.Type(node.type)].concat(optional_expr(node.default))
    Part.Variant(node) -> return types(node.payload_types)
    Part.Type(node) -> return types(node.args)
    Part.Stmt(stmt) -> return stmt_children(stmt)
    Part.Branch(node) -> return [Part.Expr(node.condition)].concat(stmts(node.body))
    Part.Arm(node) -> return [Part.Pattern(node.pattern)].concat(optional_expr(node.guard)).concat(stmts(node.body))
    Part.Pattern(pattern) -> return pattern_children(pattern)
    Part.Expr(expr) -> return expr_children(expr)
    Part.Named(node) -> return [Part.Expr(node.value)]
    Part.Entry(node) -> return [Part.Expr(node.key), Part.Expr(node.value)]
    Part.BlockParam(node) -> return optional_type(node.type)
    _ -> return []
  end
end

# The module doc is the DOC token that starts a file that has one.
def module_doc(program: Ast.Program, marks: Marks) -> List[Part]
  if program.module_doc.some? and marks.tokens.size > 0 and marks.tokens[0].kind == "DOC"
    return [Part.ModuleDoc(marks.tokens[0])]
  end

  return []
end

def decl_children(decl: Ast.Decl) -> List[Part]
  case decl
    Ast.Decl.Import(node) -> return node.names.map do |name: Ast.ImportName| Part.ImportName(name) end
    Ast.Decl.Export(node) -> return [Part.Decl(node.declaration)]
    Ast.Decl.Function(node) -> return params(node.params).concat([Part.Type(node.result)]).concat(stmts(node.body))
    Ast.Decl.Struct(node) -> return struct_children(node)
    Ast.Decl.Enum(node) -> return node.variants.map do |variant: Ast.EnumVariant| Part.Variant(variant) end
    Ast.Decl.TypeAlias(node) -> return [Part.Type(node.target)]
    Ast.Decl.Resource(node) -> return resource_children(node)
    Ast.Decl.Constant(node) -> return optional_type(node.type).push(Part.Expr(node.value))
    Ast.Decl.Reexport(_) -> return []
  end
end

# The record that the parser makes for an extern function with `out` parameters has the function's span: it is not
# text of its own.
def struct_children(node: Ast.StructDecl) -> List[Part]
  if node.record_of != ""
    return []
  end

  return node.fields.map do |field: Ast.FieldDecl| Part.Field(field) end
end

def resource_children(node: Ast.ResourceDecl) -> List[Part]
  case node.callback
    some(callback) -> return params(callback.params).concat([Part.Type(callback.result)])
    none -> return []
  end
end

def stmt_children(stmt: Ast.Stmt) -> List[Part]
  case stmt
    Ast.Stmt.Binding(node) -> return optional_type(node.type).push(Part.Expr(node.value))
    Ast.Stmt.Return(node) -> return optional_expr(node.value)
    Ast.Stmt.Expression(node) -> return [Part.Expr(node.value)]
    Ast.Stmt.If(node) -> return if_children(node)
    Ast.Stmt.While(node) -> return [Part.Expr(node.condition)].concat(stmts(node.body))
    Ast.Stmt.For(node) -> return [Part.Expr(node.iterable)].concat(stmts(node.body))
    Ast.Stmt.Case(node) -> return [Part.Expr(node.value)].concat(node.arms.map do |arm: Ast.CaseArm| Part.Arm(arm) end)
    Ast.Stmt.Control(_) -> return []
  end
end

# The branches, then the statements of the `else` body, which has no node of its own.
def if_children(node: Ast.IfStmt) -> List[Part]
  branches = node.branches.map do |branch: Ast.IfBranch| Part.Branch(branch) end
  case node.else_body
    some(body) -> return branches.concat(stmts(body))
    none -> return branches
  end
end

def pattern_children(pattern: Ast.Pattern) -> List[Part]
  case pattern
    Ast.Pattern.Variant(node) -> return nested(node.slots)
    _ -> return []
  end
end

def nested(slots: List[Ast.Slot]) -> List[Part]
  out: List[Part] = []
  for slot in slots
    case slot
      Ast.Slot.Nested(pattern) -> out = out.push(Part.Pattern(pattern))
      _ -> out = out
    end
  end

  return out
end

def expr_children(expr: Ast.Expr) -> List[Part]
  case expr
    Ast.Expr.Call(node) -> return exprs(node.args)
    Ast.Expr.EnumConstructor(node) -> return exprs(node.args).concat(named(node.named))
    Ast.Expr.Invoke(node) -> return [Part.Expr(node.target)].concat(exprs(node.args))
    Ast.Expr.Construct(node) -> return named(node.args)
    Ast.Expr.Update(node) -> return [Part.Expr(node.target)].concat(named(node.args))
    Ast.Expr.ListLit(node) -> return exprs(node.elements)
    Ast.Expr.MapLit(node) -> return node.entries.map do |entry: Ast.MapEntry| Part.Entry(entry) end
    Ast.Expr.FieldAccess(node) -> return [Part.Expr(node.target)]
    Ast.Expr.MethodCall(node) -> return [Part.Expr(node.target)].concat(exprs(node.args))
    Ast.Expr.Interpolation(node) -> return interpolated(node.parts)
    Ast.Expr.BlockLit(node) -> return block_params(node.params).concat(stmts(node.body))
    Ast.Expr.Index(node) -> return [Part.Expr(node.target), Part.Expr(node.index)]
    Ast.Expr.Try(node) -> return [Part.Expr(node.operand)]
    Ast.Expr.Unary(node) -> return [Part.Expr(node.operand)]
    Ast.Expr.Binary(node) -> return [Part.Expr(node.left), Part.Expr(node.right)]
    Ast.Expr.Typed(node) -> return [Part.Expr(node.target)]
    _ -> return []
  end
end

def interpolated(parts: List[Ast.Part]) -> List[Part]
  out: List[Part] = []
  for piece in parts
    case piece
      Ast.Part.Code(code) -> out = out.push(Part.Expr(code))
      Ast.Part.Text(_) -> out = out
    end
  end

  return out
end

def decls(items: List[Ast.Decl]) -> List[Part]
  return items.map do |item: Ast.Decl| Part.Decl(item) end
end

def exprs(items: List[Ast.Expr]) -> List[Part]
  return items.map do |item: Ast.Expr| Part.Expr(item) end
end

def stmts(items: List[Ast.Stmt]) -> List[Part]
  return items.map do |item: Ast.Stmt| Part.Stmt(item) end
end

def types(items: List[Ast.TypeRef]) -> List[Part]
  return items.map do |item: Ast.TypeRef| Part.Type(item) end
end

def params(items: List[Ast.Param]) -> List[Part]
  return items.map do |item: Ast.Param| Part.Param(item) end
end

def named(items: List[Ast.NamedArg]) -> List[Part]
  return items.map do |item: Ast.NamedArg| Part.Named(item) end
end

def block_params(items: List[Ast.BlockParam]) -> List[Part]
  return items.map do |item: Ast.BlockParam| Part.BlockParam(item) end
end

def optional_expr(value: Optional[Ast.Expr]) -> List[Part]
  case value
    some(found) -> return [Part.Expr(found)]
    none -> return []
  end
end

def optional_type(value: Optional[Ast.TypeRef]) -> List[Part]
  case value
    some(found) -> return [Part.Type(found)]
    none -> return []
  end
end
