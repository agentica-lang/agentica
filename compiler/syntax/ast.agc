## The syntax tree of the Agentica parser: the nodes as structs and enums.
##
## Every node has an Int id and a span. The parser numbers the nodes in post-order: a node's children have smaller ids
## than the node, siblings are numbered in source order, the first id is the one given to the parser (0 for a single
## file), there are no gaps, and the Program has the last one. To number the modules of one program without
## renumbering, parse the next file from next_free_id of the previous Program. The checker keys its types by id,
## because Agentica has no object identity.
##
## Docs (`##` comments) are a field of the declaration, field or variant they document, not a table keyed by span.
##
## A function, struct, enum, type alias, constant, field and variant also keep the span of its name (`name_span`), as
## do a field access, a method call, a parameter, a block parameter and a binding; a `for` variable keeps
## `variable_span` and a name in a pattern the span in its Slot. They serve the commands that point at a name
## (`agentica outline`, `agentica type-at`). parse_text.agc does not print any of them.

import Source from "source"
import Types from "types"

## The value of a literal or of a literal pattern. Huge keeps an integer that does not fit an Int as its digits, with a
## leading - when a pattern negates it.
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
  Reexport(ReexportDecl)
  Export(ExportDecl)
  Function(FunctionDecl)
  Struct(StructDecl)
  Enum(EnumDecl)
  TypeAlias(TypeAliasDecl)
  Resource(ResourceDecl)
  Constant(ConstDecl)
end

## An import: import Alias from "path" (alias is `some`, names is empty), or import {A, B as C} from "path" (alias is
## `none`, names has at least one entry).
export struct ImportDecl
  id: Int
  path: String
  alias: Optional[String]
  names: List[ImportName]
  span: Source.Span
end

## One entry of an import list: the exported name, the name this file binds (the same without `as`), and the span of
## each (equal without `as`). It has no id: it is part of its ImportDecl.
export struct ImportName
  name: String
  local: String
  span: Source.Span
  local_span: Source.Span
end

## A re-export: `export Alias.name` or `export Alias.TypeName` passes on a name that the file imports under `alias`.
## The spans are of the whole line, of the alias and of the name.
export struct ReexportDecl
  id: Int
  alias: String
  name: String
  alias_span: Source.Span
  name_span: Source.Span
  span: Source.Span
end

## export before a def, struct or enum; its doc is the doc of the declaration.
export struct ExportDecl
  id: Int
  declaration: Decl
  doc: Optional[String]
  span: Source.Span
end

## A module constant: [export] NAME[: Type] = value (docs/future/44-module-constants.md). Unlike the other declarations
## it is not wrapped by an ExportDecl: exported says whether `export` was written, and the span starts at it. The
## linker clears exported.
export struct ConstDecl
  id: Int
  name: String
  name_span: Source.Span
  type: Optional[TypeRef]
  value: Expr
  exported: Bool
  doc: Optional[String]
  span: Source.Span
end

## def name(params) -> Result with its body. A function of an `extern "library"` block has native `some` and no body;
## its parameter and result types are already the Agentica types of the C types it was written with.
## type_parameters are the names of a generic function (def first_or[T](...)) and type_parameter_spans their spans, in
## the same order; both are empty for any other function, and always for an extern one.
export struct FunctionDecl
  id: Int
  name: String
  name_span: Source.Span
  type_parameters: List[String]
  type_parameter_spans: List[Source.Span]
  params: List[Param]
  result: TypeRef
  body: List[Stmt]
  doc: Optional[String]
  native: Optional[Native]
  span: Source.Span
end

## The C side of an extern function: the library it is in, as written, its C name (the def's name or the string after
## `=`; the linker renames the function, never this), the codes of its C types, the result's first and then one per
## parameter (i C.Int32, l C.Int64, g C.Int8, h C.Int16, u C.UInt8, w C.UInt16, j C.UInt32, n C.Long, d C.Double, f
## C.Float, b C.Bool, s C.String, p C.Pointer, y C.Bytes, r a resource of the block, v Void; an `out` parameter has the
## capital of its code (I, L, G, H, U, W, J, N, D, F, B, P or R), and a variadic function has a `.` where its `...` is,
## before the codes of its variadic part; a C.Function first parameter, the address of the function to call, is c, and
## a C.Function last parameter, the free function of the resource the call makes (or the sole one of a def that returns
## such a resource), is e: neither goes to C, and the C name of a call through a pointer is only shown; a struct of the
## block, passed or returned by value, is its layout code: { then the code of each field in order (an integer code, d,
## f, b, p or a nested struct's layout code), then }), and whether it is a `compute def`, which runs on the VM's
## compute pool while the task waits.
## A function that returns a resource has the resource's name as written and the C name of its free function (or
## "C.Function"; &NAME for a free_ref: resource); both are "" otherwise. outs holds the same for each out resource,
## in order. A function with out parameters has none of them in its params: it returns its record
## (StructDecl.record_of), with the C result first. with_types is true when the block of the function declares a
## resource or a struct, which puts all its functions with the types in the declaration order.
export struct Native
  library: String
  symbol: String
  codes: String
  compute: Bool
  resource: String
  free: String
  outs: List[NativeResource]
  with_types: Bool
end

## A resource that an out parameter of an extern function gives: its name as written and the C name of its free
## function.
export struct NativeResource
  name: String
  free: String
end

## One parameter of a function, with its default value when `NAME: type = expression` gave one. The default is an
## ordinary expression of the file; the checker accepts only a constant (CHECK-DEFAULT-VALUE), and the linker resolves
## its names in the file that declares the function.
export struct Param
  id: Int
  name: String
  name_span: Source.Span
  type: TypeRef
  default: Optional[Expr]
  span: Source.Span
end

## A struct and its fields. record_of is "" for a struct written in the program, and for the record that the parser
## makes for an extern function with `out` parameters the name of that function: a field `result` with the C result
## (none for Void), then one field per out parameter, named after it. The record has the function's span and name
## span, and comes right after the function. layout is "" for every struct but a C struct of an extern block, which has
## its layout code (Native.codes): { then the code of each field in order, then }. type_parameters are the names of
## a generic struct (struct Box[T]); empty for any other, and always for a record or a C struct.
export struct StructDecl
  id: Int
  name: String
  name_span: Source.Span
  type_parameters: List[String]
  fields: List[FieldDecl]
  doc: Optional[String]
  record_of: String
  layout: String
  span: Source.Span
end

## One field of a struct, with its default value when `name: Type = expression` gave one. Like a parameter default, it
## is an ordinary expression of the file; the checker accepts only a constant (CHECK-DEFAULT-VALUE), the linker
## resolves its names in the file that declares the struct, and a constructor that leaves the field out gets the value.
export struct FieldDecl
  id: Int
  name: String
  name_span: Source.Span
  type: TypeRef
  default: Optional[Expr]
  doc: Optional[String]
  span: Source.Span
end

## An enum with its type parameters and variants.
export struct EnumDecl
  id: Int
  name: String
  name_span: Source.Span
  type_parameters: List[String]
  variants: List[EnumVariant]
  doc: Optional[String]
  span: Source.Span
end

## A type alias, with the type parameters of a generic one (type Matrix[T] = List[List[T]]; empty for type Grid = ...).
export struct TypeAliasDecl
  id: Int
  name: String
  name_span: Source.Span
  type_parameters: List[String]
  target: TypeRef
  doc: Optional[String]
  span: Source.Span
end

## A resource of an extern block (`resource Db, free: db_close`): a nominal type for the C pointers that the block's
## functions return, and the C name of the function of the same library that frees one, or "C.Function" when each
## value has its own free function, a C function pointer that the call which makes it takes. by_ref is true for
## `free_ref: db_close`, a free function that takes the address of the pointer (void f(T **)). A callback of the block
## (`callback Compare(a: C.Int32) -> C.Int32`) is a resource too, made by Native.callback and freed by the VM: free
## is "" and callback holds its C function type; it is `none` for every other resource.
export struct ResourceDecl
  id: Int
  name: String
  name_span: Source.Span
  free: String
  by_ref: Bool
  callback: Optional[Callback]
  doc: Optional[String]
  span: Source.Span
end

## The C function type of a callback of an extern block: its parameters and result with the Agentica types that the
## function given to Native.callback takes and returns (C.Int32 is Int, Void stays Void), and the codes of the C
## types, the result's first, as in Native.codes (an integer code, d, f, b, p, s for a parameter, v for a result).
export struct Callback
  params: List[Param]
  result: TypeRef
  codes: String
end

## One variant of an enum, with the types of its payload.
export struct EnumVariant
  id: Int
  name: String
  name_span: Source.Span
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

## name = value, name: Type = value, or the desugared name += value. `name_span` is the name on the left.
export struct Binding
  id: Int
  name: String
  name_span: Source.Span
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

## if with its elsif branches. else_body is `some` when the else keyword is written, even for an empty body.
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
  variable_span: Source.Span
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

## One arm of a case: a pattern, an optional guard (`pattern if condition ->`) and a body. The guard is a Bool
## expression that may read the names the pattern binds.
export struct CaseArm
  id: Int
  pattern: Pattern
  guard: Optional[Expr]
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

## An enum variant pattern, or ok(...) and error(...) as Result variants, with one slot for each payload position.
export struct VariantPattern
  id: Int
  enum_name: String
  variant_name: String
  slots: List[Slot]
  span: Source.Span
end

## One payload position of a variant pattern: a name that binds the value (with the span of the name), `_` that drops
## it, or a nested pattern (a literal, or another variant, to any depth). A name and `_` have no node id of their own,
## so a pattern with no nested part numbers the nodes of the tree as it did before nested patterns existed.
export enum Slot
  Bind(String, Source.Span)
  Skip
  Nested(Pattern)
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
  Update(StructUpdate)
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
  Typed(TypedTarget)
  ConstRef(ConstRef)
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

## A call by name, with the piped value as first argument after |>. parenthesized records whether the source had
## parentheses; only such a call may be the target of |>.
export struct Call
  id: Int
  name: String
  args: List[Expr]
  piped: Bool
  parenthesized: Bool
  span: Source.Span
end

## Enum.Variant(args), also through a module alias. named is empty from the parser. The linker fills it, and leaves
## args empty, for a call written with names such as Enum.Variant(x: 1), which the parser reads as a Construct; the
## checker refuses it (variants take positional arguments).
export struct EnumConstructor
  id: Int
  enum_name: String
  variant_name: String
  args: List[Expr]
  named: List[NamedArg]
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

## target.with(name: value, ...): a copy of a struct with the named fields changed. There is at least one argument.
## visible is `none` from the parser. The linker sets it to the sorted linked names of the user structs that the file
## of the update may build: its own and the exported ones of the files it imports (a builtin record is always allowed,
## so it is not listed). The checker refuses an update of any other user struct (CHECK-IMPORT-NAME). It is data in the
## node, not a predicate.
export struct StructUpdate
  id: Int
  target: Expr
  args: List[NamedArg]
  visible: Optional[List[String]]
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

## target.name without parentheses. `name_span` is the span of the name after the dot.
export struct FieldAccess
  id: Int
  target: Expr
  name: String
  name_span: Source.Span
  span: Source.Span
end

## target.name(args), with a trailing block as the last argument. `name_span` is the span of the name after the dot.
export struct MethodCall
  id: Int
  target: Expr
  name: String
  name_span: Source.Span
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
  name_span: Source.Span
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

## A binary operator; op is the token kind (plus, and, equal, dot-dot, ...), and a compound assignment is desugared to
## plus, minus, multiply, divide or modulo.
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

## The read of a module constant, made by the linker from NAME (name is the linked name), and the receiver of a
## rewritten NAME.method(...) or NAME.field. A receiver made from a call has the id total + the id of the call, where
## total is the number of ids of the program, so it does not clash with a node of the parser (see Linker.Linked.ids).
export struct ConstRef
  id: Int
  name: String
  span: Source.Span
end

## The receiver of a method call that the checker has already checked, with its type, so the builtin rule of the method
## checks it as the first argument without checking it twice. The parser never makes it. id
## and span are those of the receiver.
export struct TypedTarget
  id: Int
  target: Expr
  type: Types.Type
  span: Source.Span
end

## The id of an expression node.
export def expr_id(expr: Expr) -> Int
  case expr
    Expr.Literal(node) -> return node.id
    Expr.Name(node) -> return node.id
    Expr.Call(node) -> return node.id
    Expr.EnumConstructor(node) -> return node.id
    Expr.FunctionRef(node) -> return node.id
    Expr.Invoke(node) -> return node.id
    Expr.Construct(node) -> return node.id
    Expr.Update(node) -> return node.id
    Expr.ListLit(node) -> return node.id
    Expr.MapLit(node) -> return node.id
    Expr.FieldAccess(node) -> return node.id
    Expr.MethodCall(node) -> return node.id
    Expr.Interpolation(node) -> return node.id
    Expr.BlockLit(node) -> return node.id
    Expr.Index(node) -> return node.id
    Expr.Try(node) -> return node.id
    Expr.Unary(node) -> return node.id
    Expr.Binary(node) -> return node.id
    Expr.TypeName(node) -> return node.id
    Expr.Typed(node) -> return node.id
    Expr.ConstRef(node) -> return node.id
  end
end

## The span of an expression node.
export def expr_span(expr: Expr) -> Source.Span
  case expr
    Expr.Literal(node) -> return node.span
    Expr.Name(node) -> return node.span
    Expr.Call(node) -> return node.span
    Expr.EnumConstructor(node) -> return node.span
    Expr.FunctionRef(node) -> return node.span
    Expr.Invoke(node) -> return node.span
    Expr.Construct(node) -> return node.span
    Expr.Update(node) -> return node.span
    Expr.ListLit(node) -> return node.span
    Expr.MapLit(node) -> return node.span
    Expr.FieldAccess(node) -> return node.span
    Expr.MethodCall(node) -> return node.span
    Expr.Interpolation(node) -> return node.span
    Expr.BlockLit(node) -> return node.span
    Expr.Index(node) -> return node.span
    Expr.Try(node) -> return node.span
    Expr.Unary(node) -> return node.span
    Expr.Binary(node) -> return node.span
    Expr.TypeName(node) -> return node.span
    Expr.Typed(node) -> return node.span
    Expr.ConstRef(node) -> return node.span
  end
end

## The span of a pattern node.
export def pattern_span(pattern: Pattern) -> Source.Span
  case pattern
    Pattern.Wildcard(node) -> return node.span
    Pattern.Literal(node) -> return node.span
    Pattern.Variant(node) -> return node.span
  end
end

## The span of a statement node.
export def stmt_span(stmt: Stmt) -> Source.Span
  case stmt
    Stmt.Binding(node) -> return node.span
    Stmt.Return(node) -> return node.span
    Stmt.Expression(node) -> return node.span
    Stmt.If(node) -> return node.span
    Stmt.While(node) -> return node.span
    Stmt.For(node) -> return node.span
    Stmt.Control(node) -> return node.span
    Stmt.Case(node) -> return node.span
  end
end

## The first id the next file can use: one more than the id of the Program.
export def next_free_id(program: Program) -> Int
  return program.id + 1
end
