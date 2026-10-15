## The syntax tree of the Agentica parser: the nodes of src/ast.rkt as structs and enums.
##
## Every node has an Int id and a span. The parser numbers the nodes in post-order: a node's children have smaller ids than the node, siblings are numbered in source order, the first id is the one given to the parser (0 for a single file), there are no gaps, and the Program has the last one. To number the modules of one program without renumbering, parse the next file from next_free_id of the previous Program. The checker keys its types by id, because Agentica has no object identity.
##
## Docs (`##` comments) are a field of the declaration, field or variant they document, not a table keyed by span.

import "source" as Source

## A value that may be absent; where src/ast.rkt uses #f.
export enum Optional[T]
  Present(T)
  Absent
end

## The value of a literal or of a literal pattern. Huge keeps an integer that does not fit an Int as its digits, with a leading - when a pattern negates it.
export enum LitValue
  Whole(Int)
  Huge(String)
  Real(Float)
  Text(String)
  Flag(Bool)
  Nothing
end

## A type written in the source, such as List[Int] or Mod.Type.
export struct TypeRef
  id: Int
  name: String
  args: List[TypeRef]
  span: Source.Span
end

## The root of a parsed file. It has the last id of the tree.
export struct Program
  id: Int
  declarations: List[Decl]
  module_doc: Optional[String]
  span: Source.Span
end

## A top-level declaration.
export enum Decl
  Import(ImportDecl)
  Export(ExportDecl)
  Function(FunctionDecl)
  Struct(StructDecl)
  Enum(EnumDecl)
end

## import "path" as Alias.
export struct ImportDecl
  id: Int
  path: String
  alias: String
  span: Source.Span
end

## export before a def, struct or enum; its doc is the doc of the declaration.
export struct ExportDecl
  id: Int
  declaration: Decl
  doc: Optional[String]
  span: Source.Span
end

## def name(params) -> Result with its body.
export struct FunctionDecl
  id: Int
  name: String
  params: List[Param]
  result: TypeRef
  body: List[Stmt]
  doc: Optional[String]
  span: Source.Span
end

## One parameter of a function.
export struct Param
  id: Int
  name: String
  type: TypeRef
  span: Source.Span
end

## A struct and its fields.
export struct StructDecl
  id: Int
  name: String
  fields: List[FieldDecl]
  doc: Optional[String]
  span: Source.Span
end

## One field of a struct.
export struct FieldDecl
  id: Int
  name: String
  type: TypeRef
  doc: Optional[String]
  span: Source.Span
end

## An enum with its type parameters and variants.
export struct EnumDecl
  id: Int
  name: String
  type_parameters: List[String]
  variants: List[EnumVariant]
  doc: Optional[String]
  span: Source.Span
end

## One variant of an enum, with the types of its payload.
export struct EnumVariant
  id: Int
  name: String
  payload_types: List[TypeRef]
  doc: Optional[String]
  span: Source.Span
end

## A statement.
export enum Stmt
  Binding(Binding)
  Return(Return)
  Expression(ExprStmt)
  If(IfStmt)
  While(WhileStmt)
  For(ForStmt)
  Control(LoopControl)
  Case(CaseStmt)
end

## name = value, name: Type = value, or the desugared name += value.
export struct Binding
  id: Int
  name: String
  type: Optional[TypeRef]
  value: Expr
  span: Source.Span
end

## return with an optional value.
export struct Return
  id: Int
  value: Optional[Expr]
  span: Source.Span
end

## An expression used as a statement.
export struct ExprStmt
  id: Int
  value: Expr
  span: Source.Span
end

## The if or elsif part of an if statement: a condition and a body.
export struct IfBranch
  id: Int
  condition: Expr
  body: List[Stmt]
  span: Source.Span
end

## if with its elsif branches. else_body is Present when the else keyword is written, even for an empty body.
export struct IfStmt
  id: Int
  branches: List[IfBranch]
  else_body: Optional[List[Stmt]]
  span: Source.Span
end

## while condition ... end.
export struct WhileStmt
  id: Int
  condition: Expr
  body: List[Stmt]
  span: Source.Span
end

## for variable in iterable ... end.
export struct ForStmt
  id: Int
  variable: String
  iterable: Expr
  body: List[Stmt]
  span: Source.Span
end

## break or next; kind is that word.
export struct LoopControl
  id: Int
  kind: String
  span: Source.Span
end

## case value ... end with its arms.
export struct CaseStmt
  id: Int
  value: Expr
  arms: List[CaseArm]
  span: Source.Span
end

## One arm of a case: a pattern and a body.
export struct CaseArm
  id: Int
  pattern: Pattern
  body: List[Stmt]
  span: Source.Span
end

## The pattern of a case arm.
export enum Pattern
  Wildcard(WildcardPattern)
  Literal(LiteralPattern)
  Variant(VariantPattern)
end

## The pattern _.
export struct WildcardPattern
  id: Int
  span: Source.Span
end

## A literal pattern: a number (possibly negative), a string, true, false or nil.
export struct LiteralPattern
  id: Int
  value: LitValue
  span: Source.Span
end

## An enum variant pattern, or ok(...) and error(...) as Result variants. A binding is Absent for _.
export struct VariantPattern
  id: Int
  enum_name: String
  variant_name: String
  bindings: List[Optional[String]]
  span: Source.Span
end

## An expression.
export enum Expr
  Literal(Literal)
  Name(NameRef)
  Call(Call)
  EnumConstructor(EnumConstructor)
  FunctionRef(FunctionRef)
  Invoke(Invoke)
  Construct(Construct)
  ListLit(ListLit)
  MapLit(MapLit)
  FieldAccess(FieldAccess)
  MethodCall(MethodCall)
  Interpolation(Interpolation)
  BlockLit(BlockLit)
  Index(IndexAccess)
  Try(TryExpr)
  Unary(Unary)
  Binary(Binary)
  TypeName(TypeName)
end

## A number, string, true, false or nil.
export struct Literal
  id: Int
  value: LitValue
  span: Source.Span
end

## A variable name.
export struct NameRef
  id: Int
  name: String
  span: Source.Span
end

## A call by name, with the piped value as first argument after |>. parenthesized records whether the source had parentheses; only such a call may be the target of |>.
export struct Call
  id: Int
  name: String
  args: List[Expr]
  piped: Bool
  parenthesized: Bool
  span: Source.Span
end

## Enum.Variant(args), also through a module alias.
export struct EnumConstructor
  id: Int
  enum_name: String
  variant_name: String
  args: List[Expr]
  span: Source.Span
end

## &name or &Alias.name.
export struct FunctionRef
  id: Int
  name: String
  span: Source.Span
end

## target.call(args): a call of a function value.
export struct Invoke
  id: Int
  target: Expr
  args: List[Expr]
  span: Source.Span
end

## name: value in a struct construction.
export struct NamedArg
  id: Int
  name: String
  value: Expr
  span: Source.Span
end

## Type(name: value, ...): a struct construction.
export struct Construct
  id: Int
  type_name: String
  args: List[NamedArg]
  span: Source.Span
end

## [a, b, c].
export struct ListLit
  id: Int
  elements: List[Expr]
  span: Source.Span
end

## key: value in a map literal.
export struct MapEntry
  id: Int
  key: Expr
  value: Expr
  span: Source.Span
end

## {key: value, ...}.
export struct MapLit
  id: Int
  entries: List[MapEntry]
  span: Source.Span
end

## target.name without parentheses.
export struct FieldAccess
  id: Int
  target: Expr
  name: String
  span: Source.Span
end

## target.name(args), with a trailing block as the last argument.
export struct MethodCall
  id: Int
  target: Expr
  name: String
  args: List[Expr]
  span: Source.Span
end

## One part of an interpolated string: text, or an expression.
export enum Part
  Text(String)
  Code(Expr)
end

## A string with #{...} parts; empty text parts are left out.
export struct Interpolation
  id: Int
  parts: List[Part]
  span: Source.Span
end

## do |params| body end.
export struct BlockLit
  id: Int
  params: List[BlockParam]
  body: List[Stmt]
  span: Source.Span
end

## One parameter of a block, with an optional type.
export struct BlockParam
  id: Int
  name: String
  type: Optional[TypeRef]
  span: Source.Span
end

## target[index].
export struct IndexAccess
  id: Int
  target: Expr
  index: Expr
  span: Source.Span
end

## try operand.
export struct TryExpr
  id: Int
  operand: Expr
  span: Source.Span
end

## - or not applied to an operand; op is the token kind (minus or not).
export struct Unary
  id: Int
  op: String
  op_span: Source.Span
  operand: Expr
  span: Source.Span
end

## A binary operator; op is the token kind (plus, and, equal, dot-dot, ...), and a compound assignment is desugared to plus, minus, multiply, divide or modulo.
export struct Binary
  id: Int
  op: String
  op_span: Source.Span
  left: Expr
  right: Expr
  span: Source.Span
end

## A type name in expression position: Foo or Mod.Foo.
export struct TypeName
  id: Int
  name: String
  span: Source.Span
end

## The first id the next file can use: one more than the id of the Program.
export def next_free_id(program: Program) -> Int
  return program.id + 1
end
