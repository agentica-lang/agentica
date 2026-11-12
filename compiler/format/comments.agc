## The plain comments of a file attached to its tree, the first step of the
## formatter. The lexer keeps the comments in a side list (`Lexer.lex_with_comments`), so the tree, the checker and
## the later stages never see them; this pass gives each comment one node and one role, before any layout.
##
## The nodes are an outline of the tree: one entry per node with a span (declarations, parameters, fields, variants,
## types, statements, `if` branches, `case` arms, patterns, expressions, the stages of a pipe chain, named arguments,
## map entries, block parameters and import names), plus the module doc, which the tree keeps as text only. Each has
## the kind of its tree node and its span cut at its last token that is not a line break, because a parsed span can
## end with the line break after the node. The outline is built with a worklist and no recursion, so a deep tree
## cannot reach the limit of VM calls.
##
## The rules, after Prettier and syntax_tree: for each comment, the enclosing node is the deepest node whose span holds
## it, and the preceding and following nodes are the closest children of that node before and after it. A comment
## alone on its line leads the following node, else trails the preceding one; a comment after code trails the
## preceding node, else leads the following one; with neither it dangles on the enclosing node. The positions where
## that is wrong are fixed by keyword, read from the tokens, since `elsif`, `else`, `end` and a chain's `.` have no
## node: see `place`. One is fixed by node: a comment after the last statement of an `if` branch or a `case` arm, on
## its line, trails that statement, not the branch (`body_end`).

import Ast from "../syntax/ast"
import Source from "../syntax/source"
import Tokens from "../syntax/token"

# The kinds of the statement nodes.
STATEMENT_KINDS = Set.new([
  "Binding", "Return", "ExprStmt", "IfStmt", "WhileStmt", "ForStmt", "LoopControl", "CaseStmt",
])
# The nodes a comment before `end` trails: a statement, or a field or variant before the `end` of its declaration.
BODY_END_KINDS = STATEMENT_KINDS.union(Set.new(["FieldDecl", "EnumVariant"]))

## A node of the outline: the name of its tree node (`FunctionDecl`, `Param`, `IfStmt`, `Call`, ... and `ModuleDoc`
## for the module doc), its span from its first token to its last token that is not a line break, the index of its
## parent in the outline (-1 for the Program, which is always the first entry), and its key (`key_of` of its kind and
## its span as parsed), by which the layout finds the comments of a tree node.
export struct Node
  kind: String
  span: Source.Span
  parent: Int
  key: String
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

# The outline with, for each node, where its children start in it and how many there are, and where each node starts
# and stops. A node's children are queued together, so they sit side by side; they come in source order and do not
# overlap, so their starts and their stops both ascend, and the searches among them are binary.
struct Outline
  nodes: List[Node]
  first: List[Int]
  count: List[Int]
  starts: List[Int]
  stops: List[Int]
end

# The tokens that are not line breaks or the end of the text, with their offsets for the binary searches.
struct Marks
  tokens: List[Tokens.Token]
  starts: List[Int]
  stops: List[Int]
end

## A stage of a pipe chain: the piped call (`x |> f(a)` is the call `f(x, a)`, whose first argument is the rest of the
## chain), and whether the stage is written `|> try f(a)`.
export struct PipeStage
  call: Ast.Call
  tried: Bool
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
  Stage(Ast.Call)
  Named(Ast.NamedArg)
  Entry(Ast.MapEntry)
  BlockParam(Ast.BlockParam)
end

## Attaches each comment of `comments` to a node of `program`, which was parsed from `tokens`.
export def attach(program: Ast.Program, tokens: List[Tokens.Token], comments: List[Tokens.Comment]) -> Attachment
  marks = marks_of(tokens)
  outline = outline_of(program, marks)
  placed = comments.map do |comment: Tokens.Comment| place(outline, marks, comment) end
  Attachment(nodes: outline.nodes, comments: placed)
end

## The key of a tree node of kind `kind` (as `Node.kind` names it) with the span `span` as the parser gave it. Two
## nodes of one tree never share a key: a node and its child of the same kind never have the same span.
export def key_of(kind: String, span: Source.Span) -> String = "#{kind}:#{span.start.offset}:#{span.stop.offset}"

## The name of a role, as the text form prints it.
export def role_name(role: Role) -> String
  case role
    Role.Leading -> "leading"
    Role.Trailing -> "trailing"
    Role.Dangling -> "dangling"
  end
end

## The kind of a declaration, as `Node.kind` names it.
export def decl_kind(decl: Ast.Decl) -> String
  case decl
    Ast.Decl.Import(_) -> "ImportDecl"
    Ast.Decl.Reexport(_) -> "ReexportDecl"
    Ast.Decl.Export(_) -> "ExportDecl"
    Ast.Decl.Function(_) -> "FunctionDecl"
    Ast.Decl.Struct(_) -> "StructDecl"
    Ast.Decl.Enum(_) -> "EnumDecl"
    Ast.Decl.TypeAlias(_) -> "TypeAliasDecl"
    Ast.Decl.Resource(_) -> "ResourceDecl"
    Ast.Decl.Constant(_) -> "ConstDecl"
    Ast.Decl.Module(_) -> "ModuleDecl"
  end
end

## The kind of a statement, as `Node.kind` names it.
export def stmt_kind(stmt: Ast.Stmt) -> String
  case stmt
    Ast.Stmt.Binding(_) -> "Binding"
    Ast.Stmt.Return(_) -> "Return"
    Ast.Stmt.Expression(_) -> "ExprStmt"
    Ast.Stmt.If(_) -> "IfStmt"
    Ast.Stmt.While(_) -> "WhileStmt"
    Ast.Stmt.For(_) -> "ForStmt"
    Ast.Stmt.Control(_) -> "LoopControl"
    Ast.Stmt.Case(_) -> "CaseStmt"
  end
end

## The kind of a pattern, as `Node.kind` names it.
export def pattern_kind(pattern: Ast.Pattern) -> String
  case pattern
    Ast.Pattern.Wildcard(_) -> "WildcardPattern"
    Ast.Pattern.Literal(_) -> "LiteralPattern"
    Ast.Pattern.Variant(_) -> "VariantPattern"
    Ast.Pattern.Or(_) -> "OrPattern"
  end
end

## The kind of a expression, as `Node.kind` names it.
export def expr_kind(expr: Ast.Expr) -> String
  case expr
    Ast.Expr.Literal(_) -> "Literal"
    Ast.Expr.Name(_) -> "NameRef"
    Ast.Expr.Call(_) -> "Call"
    Ast.Expr.EnumConstructor(_) -> "EnumConstructor"
    Ast.Expr.FunctionRef(_) -> "FunctionRef"
    Ast.Expr.Invoke(_) -> "Invoke"
    Ast.Expr.Construct(_) -> "Construct"
    Ast.Expr.Update(_) -> "StructUpdate"
    Ast.Expr.ListLit(_) -> "ListLit"
    Ast.Expr.MapLit(_) -> "MapLit"
    Ast.Expr.FieldAccess(_) -> "FieldAccess"
    Ast.Expr.MethodCall(_) -> "MethodCall"
    Ast.Expr.Interpolation(_) -> "Interpolation"
    Ast.Expr.BlockLit(_) -> "BlockLit"
    Ast.Expr.Index(_) -> "IndexAccess"
    Ast.Expr.Try(_) -> "TryExpr"
    Ast.Expr.Unary(_) -> "Unary"
    Ast.Expr.Binary(_) -> "Binary"
    Ast.Expr.TypeName(_) -> "TypeName"
    Ast.Expr.Typed(_) -> "TypedTarget"
    Ast.Expr.ConstRef(_) -> "ConstRef"
    Ast.Expr.RegexLit(_) -> "RegexLit"
    Ast.Expr.EagLit(_) -> "EagLit"
    Ast.Expr.Case(_) -> "CaseStmt"
  end
end

## The stage that `expr` ends a chain with: a piped call, or a `try` of one. None for any other expression. The layout
## and the comment attachment both walk a chain through this, so their stages and keys cannot differ.
export def pipe_stage(expr: Ast.Expr) -> Optional[PipeStage]
  case expr
    Ast.Expr.Call(node) -> return some(PipeStage(call: node, tried: false)) if node.piped

    Ast.Expr.Try(node) ->
      case node.operand
        Ast.Expr.Call(call) -> return some(PipeStage(call: call, tried: true)) if call.piped

        _ -> return none
      end

    _ -> return none
  end

  none
end

def marks_of(tokens: List[Tokens.Token]) -> Marks
  kept = tokens.select do |token: Tokens.Token| token.kind != "NL" and token.kind != "EOF" end
  starts = kept.map do |token: Tokens.Token| token.span.start.offset end
  stops = kept.map do |token: Tokens.Token| token.span.stop.offset end
  Marks(tokens: kept, starts: starts, stops: stops)
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
    raw = span_of(pending.part)
    kind = kind_of(pending.part)
    shown = widened(pending.part, raw)
    nodes = nodes.push(Node(kind: kind, span: tight(shown, marks), parent: pending.parent, key: key_of(kind, raw)))
    children = children_of(pending.part, marks).select do |part: Part| written?(span_of(part)) end
    first = first.push(queue.size)
    count = count.push(children.size)
    for child in children
      queue = queue.push(Pending(part: child, parent: at))
    end

    at += 1
  end

  starts = nodes.map do |node: Node| node.span.start.offset end
  stops = nodes.map do |node: Node| node.span.stop.offset end
  Outline(nodes: nodes, first: first, count: count, starts: starts, stops: stops)
end

# The span a node holds in the outline. The parser gives a piped call (`x |> f(a)` is the call `f(x, a)`) the span of
# the call written on the right, so its first argument, the rest of the chain, lies before it; the node of a chain
# covers it all, from the start of the first operand, to hold the comments between the stages. The key of the node
# stays the one of the span as parsed.
def widened(part: Part, raw: Source.Span) -> Source.Span
  case part
    Part.Expr(expr) ->
      start = chain_start(expr)
      return raw.with(start: start) if start.offset < raw.start.offset

      raw
    _ -> raw
  end
end

# Where the chain that ends in `expr` starts: the first operand of its `|>` stages, or the start of `expr` itself when
# it is not a piped call (or a `try` of one).
def chain_start(expr: Ast.Expr) -> Source.Position
  start = Ast.expr_span(expr).start
  current = expr
  looping = true
  while looping
    looping = false
    case pipe_stage(current)
      some(stage) ->
        current = stage.call.args[0]
        looping = true
        here = Ast.expr_span(current).start
        if here.offset < start.offset
          start = here
        end

      none -> looping = false
    end
  end

  start
end

# A node the parser made without text of its own has an empty span; it gets no comment.
def written?(span: Source.Span) -> Bool = span.stop.offset > span.start.offset

# The span cut at its last token that is not a line break.
def tight(span: Source.Span, marks: Marks) -> Source.Span
  last = last_at_or_before(marks.stops, span.stop.offset)
  return span if last < 0 or marks.stops[last] <= span.start.offset

  span.with(stop: marks.tokens[last].span.stop)
end

# The index of the last value of the ascending `values` that is at most `limit`, or -1.
def last_at_or_before(values: List[Int], limit: Int) -> Int = last_in(values, 0, values.size, limit)

# The index of the last value of `values[from...to]`, ascending, that is at most `limit`, or `from - 1`.
def last_in(values: List[Int], from: Int, to: Int, limit: Int) -> Int
  low = from
  high = to
  while low < high
    middle = (low + high) / 2
    if values[middle] <= limit
      low = middle + 1
    else
      high = middle
    end
  end

  low - 1
end

# The index of the first value of the ascending `values` that is at least `limit`, or the size of the list.
def first_at_or_after(values: List[Int], limit: Int) -> Int = first_in(values, 0, values.size, limit)

# The index of the first value of `values[from...to]`, ascending, that is at least `limit`, or `to`.
def first_in(values: List[Int], from: Int, to: Int, limit: Int) -> Int
  low = from
  high = to
  while low < high
    middle = (low + high) / 2
    if values[middle] < limit
      low = middle + 1
    else
      high = middle
    end
  end

  low
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

    # Inside the parentheses of a statement's value, before it: the layout has no place for it between `=` and the
    # value, so it leads the statement.
    if value_follows?(outline, enclosing, following)
      return Attached(comment: comment, node: enclosing, role: Role.Leading, keyword: "")
    end

    return by_order(comment, enclosing, following, preceding, Role.Leading, Role.Trailing)
  end

  # After the `(` of a statement's value, on the same line: like the comment alone on a line there, it leads the
  # statement.
  if prior == "left-paren" and value_follows?(outline, enclosing, following)
    return Attached(comment: comment, node: enclosing, role: Role.Leading, keyword: "")
  end

  by_order(comment, enclosing, body_end(outline, preceding), following, Role.Trailing, Role.Leading)
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
  return Attached(comment: comment, node: first, role: first_role, keyword: "") if first >= 0

  return Attached(comment: comment, node: second, role: second_role, keyword: "") if second >= 0

  Attached(comment: comment, node: enclosing, role: Role.Dangling, keyword: "")
end

def token_kind(marks: Marks, index: Int) -> String
  return "" if index < 0 or index >= marks.tokens.size

  marks.tokens[index].kind
end

# The deepest node whose span holds `offset`, found from the Program down; the Program when no node holds it. At each
# level the only child that can hold it is the last one starting at or before it.
def enclosing_of(outline: Outline, offset: Int) -> Int
  current = 0
  looking = true
  while looking
    first = outline.first[current]
    child = last_in(outline.starts, first, first + outline.count[current], offset)
    looking = child >= first and holds?(outline.nodes[child].span, offset)
    if looking
      current = child
    end
  end

  current
end

def holds?(span: Source.Span, offset: Int) -> Bool = span.start.offset <= offset and offset < span.stop.offset

# The child of `parent` that ends last at or before `offset`, or -1.
def preceding_of(outline: Outline, parent: Int, offset: Int) -> Int
  first = outline.first[parent]
  found = last_in(outline.stops, first, first + outline.count[parent], offset)
  return -1 if found < first

  found
end

# The child of `parent` that starts first at or after `offset`, or -1.
def following_of(outline: Outline, parent: Int, offset: Int) -> Int
  first = outline.first[parent]
  stop = first + outline.count[parent]
  found = first_in(outline.starts, first, stop, offset)
  return -1 if found == stop

  found
end

# The last statement before an `end`: `node` itself, or for an `if` branch or a `case` arm the last statement of its
# body; -1 when there is none (no node, or an empty body).
def last_statement(outline: Outline, node: Int) -> Int
  return -1 if node < 0

  kind = outline.nodes[node].kind
  return node if kind != "IfBranch" and kind != "CaseArm"

  last = preceding_of(outline, node, outline.nodes[node].span.stop.offset)
  return last if last >= 0 and statement?(outline.nodes[last].kind)

  -1
end

# The node a comment after code trails when `node` is the node before it. An `if` branch or a `case` arm ends with its
# last statement, so a comment after that statement on its line lies past the branch and finds the branch as the node
# before it; it trails that statement, since the layout writes the comments of a branch on its head line, before the
# body. A branch or an arm with an empty body is itself, so its comment stays on the head line, and so is any other
# node.
def body_end(outline: Outline, node: Int) -> Int
  last = last_statement(outline, node)
  return last if last >= 0

  node
end

# Whether `following` is the value of `enclosing`, a statement that is one value with no body.
def value_follows?(outline: Outline, enclosing: Int, following: Int) -> Bool
  return false if following < 0

  kind = outline.nodes[enclosing].kind
  (kind == "Binding" or kind == "Return" or kind == "ExprStmt") and outline.nodes[following].kind != "TypeRef"
end

def statement?(kind: String) -> Bool = STATEMENT_KINDS.include?(kind)

def span_of(part: Part) -> Source.Span
  case part
    Part.Program(node) -> node.span
    Part.ModuleDoc(token) -> token.span
    Part.Decl(decl) -> decl_span(decl)
    Part.ImportName(node) -> node.span
    Part.Param(node) -> node.span
    Part.Field(node) -> node.span
    Part.Variant(node) -> node.span
    Part.Type(node) -> node.span
    Part.Stmt(stmt) -> Ast.stmt_span(stmt)
    Part.Branch(node) -> node.span
    Part.Arm(node) -> node.span
    Part.Pattern(pattern) -> Ast.pattern_span(pattern)
    Part.Expr(expr) -> Ast.expr_span(expr)
    Part.Stage(node) -> node.span
    Part.Named(node) -> node.span
    Part.Entry(node) -> node.span
    Part.BlockParam(node) -> node.span
  end
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

def kind_of(part: Part) -> String
  case part
    Part.Program(_) -> "Program"
    Part.ModuleDoc(_) -> "ModuleDoc"
    Part.Decl(decl) -> decl_kind(decl)
    Part.ImportName(_) -> "ImportName"
    Part.Param(_) -> "Param"
    Part.Field(_) -> "FieldDecl"
    Part.Variant(_) -> "EnumVariant"
    Part.Type(_) -> "TypeRef"
    Part.Stmt(stmt) -> stmt_kind(stmt)
    Part.Branch(_) -> "IfBranch"
    Part.Arm(_) -> "CaseArm"
    Part.Pattern(pattern) -> pattern_kind(pattern)
    Part.Expr(expr) -> expr_kind(expr)
    Part.Stage(_) -> "PipeStage"
    Part.Named(_) -> "NamedArg"
    Part.Entry(_) -> "MapEntry"
    Part.BlockParam(_) -> "BlockParam"
  end
end

# The children of a part, in source order.
def children_of(part: Part, marks: Marks) -> List[Part]
  case part
    Part.Program(node) -> module_doc(node, marks).concat(decls(node.declarations))
    Part.Decl(decl) -> decl_children(decl)
    Part.Param(node) -> [Part.Type(node.type)].concat(optional_expr(node.default))
    Part.Field(node) -> [Part.Type(node.type)].concat(optional_expr(node.default))
    Part.Variant(node) -> types(node.payload_types)
    Part.Type(node) -> types(node.args)
    Part.Stmt(stmt) -> stmt_children(stmt)
    Part.Branch(node) -> branch_children(node)
    Part.Arm(node) -> [Part.Pattern(node.pattern)].concat(optional_expr(node.guard)).concat(stmts(node.body))
    Part.Pattern(pattern) -> pattern_children(pattern)
    Part.Expr(expr) -> expr_children(expr)
    Part.Stage(node) -> exprs(node.args.drop(1))
    Part.Named(node) -> [Part.Expr(node.value)]
    Part.Entry(node) -> [Part.Expr(node.key), Part.Expr(node.value)]
    Part.BlockParam(node) -> optional_type(node.type)
    _ -> []
  end
end

# The module doc is the DOC token that starts a file that has one.
def module_doc(program: Ast.Program, marks: Marks) -> List[Part]
  if program.module_doc.some? and marks.tokens.size > 0 and marks.tokens[0].kind == "DOC"
    return [Part.ModuleDoc(marks.tokens[0])]
  end

  []
end

def decl_children(decl: Ast.Decl) -> List[Part]
  case decl
    Ast.Decl.Import(node) -> node.names.map do |name: Ast.ImportName| Part.ImportName(name) end
    Ast.Decl.Export(node) -> [Part.Decl(node.declaration)]
    Ast.Decl.Function(node) -> params(node.params).concat([Part.Type(node.result)]).concat(stmts(node.body))
    Ast.Decl.Struct(node) -> struct_children(node)
    Ast.Decl.Enum(node) -> node.variants.map do |variant: Ast.EnumVariant| Part.Variant(variant) end
    Ast.Decl.TypeAlias(node) -> [Part.Type(node.target)]
    Ast.Decl.Resource(node) -> resource_children(node)
    Ast.Decl.Constant(node) -> optional_type(node.type).push(Part.Expr(node.value))
    Ast.Decl.Module(node) -> decls(node.declarations)
    Ast.Decl.Reexport(_) -> []
  end
end

# The record that the parser makes for an extern function with `out` parameters has the function's span: it is not
# text of its own.
def struct_children(node: Ast.StructDecl) -> List[Part]
  return [] if node.record_of != ""

  node.fields.map do |field: Ast.FieldDecl| Part.Field(field) end
end

def resource_children(node: Ast.ResourceDecl) -> List[Part]
  case node.callback
    some(callback) -> params(callback.params).concat([Part.Type(callback.result)])
    none -> []
  end
end

def stmt_children(stmt: Ast.Stmt) -> List[Part]
  case stmt
    Ast.Stmt.Binding(node) -> optional_type(node.type).push(Part.Expr(node.value))
    Ast.Stmt.Return(node) -> optional_expr(node.value)
    Ast.Stmt.Expression(node) -> [Part.Expr(node.value)]
    Ast.Stmt.If(node) -> if_children(node)
    Ast.Stmt.While(node) -> [Part.Expr(node.condition)].concat(stmts(node.body))
    Ast.Stmt.For(node) -> [Part.Expr(node.iterable)].concat(stmts(node.body))
    Ast.Stmt.Case(node) -> case_parts(node)
    Ast.Stmt.Control(_) -> []
  end
end

def case_parts(node: Ast.CaseStmt) -> List[Part]
  [Part.Expr(node.value)].concat(node.arms.map do |arm: Ast.CaseArm| Part.Arm(arm) end)
end

# The branches, then the statements of the `else` body, which has no node of its own.
def if_children(node: Ast.IfStmt) -> List[Part]
  branches = node.branches.map do |branch: Ast.IfBranch| Part.Branch(branch) end
  case node.else_body
    some(body) -> branches.concat(stmts(body))
    none -> branches
  end
end

# The condition, then the body; in a guard (`return x if c`) the one statement comes first, as in the source.
def branch_children(node: Ast.IfBranch) -> List[Part]
  condition = [Part.Expr(node.condition)]
  if node.body.size == 1 and Ast.stmt_span(node.body[0]).start.offset < Ast.expr_span(node.condition).start.offset
    return stmts(node.body).concat(condition)
  end

  condition.concat(stmts(node.body))
end

def pattern_children(pattern: Ast.Pattern) -> List[Part]
  case pattern
    Ast.Pattern.Variant(node) -> nested(node.slots)
    Ast.Pattern.Or(node) -> node.patterns.map do |inner: Ast.Pattern| Part.Pattern(inner) end
    _ -> []
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

  out
end

def expr_children(expr: Ast.Expr) -> List[Part]
  case expr
    Ast.Expr.Call(node) -> call_children(node)
    Ast.Expr.EnumConstructor(node) -> exprs(node.args).concat(named(node.named))
    Ast.Expr.Invoke(node) -> [Part.Expr(node.target)].concat(exprs(node.args))
    Ast.Expr.Construct(node) -> named(node.args)
    Ast.Expr.Update(node) -> [Part.Expr(node.target)].concat(named(node.args))
    Ast.Expr.ListLit(node) -> exprs(node.elements)
    Ast.Expr.MapLit(node) -> node.entries.map do |entry: Ast.MapEntry| Part.Entry(entry) end
    Ast.Expr.FieldAccess(node) -> [Part.Expr(node.target)]
    Ast.Expr.MethodCall(node) -> [Part.Expr(node.target)].concat(exprs(node.args))
    Ast.Expr.Interpolation(node) -> interpolated(node.parts)
    Ast.Expr.BlockLit(node) -> block_params(node.params).concat(stmts(node.body))
    Ast.Expr.Index(node) -> [Part.Expr(node.target), Part.Expr(node.index)]
    Ast.Expr.Try(node) -> [Part.Expr(node.operand)]
    Ast.Expr.Unary(node) -> [Part.Expr(node.operand)]
    Ast.Expr.Binary(node) -> [Part.Expr(node.left), Part.Expr(node.right)]
    Ast.Expr.Typed(node) -> [Part.Expr(node.target)]
    Ast.Expr.Case(node) -> case_parts(node)
    _ -> []
  end
end

# The first operand of a piped call, then the stage written on the right with the rest of the arguments, so a comment
# before a `|>` leads the stage (`PipeStage`) and one after a stage trails the chain up to it.
def call_children(node: Ast.Call) -> List[Part]
  return [Part.Expr(node.args[0]), Part.Stage(node)] if node.piped

  exprs(node.args).concat(named(node.named))
end

def interpolated(parts: List[Ast.Part]) -> List[Part]
  out: List[Part] = []
  for piece in parts
    case piece
      Ast.Part.Code(code) -> out = out.push(Part.Expr(code))
      Ast.Part.Text(_) -> out = out
    end
  end

  out
end

def decls(items: List[Ast.Decl]) -> List[Part] = items.map do |item: Ast.Decl| Part.Decl(item) end

def exprs(items: List[Ast.Expr]) -> List[Part] = items.map do |item: Ast.Expr| Part.Expr(item) end

def stmts(items: List[Ast.Stmt]) -> List[Part] = items.map do |item: Ast.Stmt| Part.Stmt(item) end

def types(items: List[Ast.TypeRef]) -> List[Part] = items.map do |item: Ast.TypeRef| Part.Type(item) end

def params(items: List[Ast.Param]) -> List[Part] = items.map do |item: Ast.Param| Part.Param(item) end

def named(items: List[Ast.NamedArg]) -> List[Part] = items.map do |item: Ast.NamedArg| Part.Named(item) end

def block_params(items: List[Ast.BlockParam]) -> List[Part]
  items.map do |item: Ast.BlockParam| Part.BlockParam(item) end
end

def optional_expr(value: Optional[Ast.Expr]) -> List[Part]
  case value
    some(found) -> [Part.Expr(found)]
    none -> []
  end
end

def optional_type(value: Optional[Ast.TypeRef]) -> List[Part]
  case value
    some(found) -> [Part.Type(found)]
    none -> []
  end
end
