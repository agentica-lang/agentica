## The Agentica parser: the tree, the spans and the first diagnostic of a program.
##
## It is a recursive descent parser. Every function takes the context (Env, parse_base.agc), a position and the next
## free node id, and returns a Result: the node, the next position and id, or the packed diagnostic. The grammar
## functions follow the grammar; the notable choices are listed where they are made: precedence climbing
## for the binary operators, ids assigned at construction, and the nesting limit.

import Diag from "../diagnostics/diagnostic"
import Ast from "ast"
import Base from "parse_base"
import Tokens from "token"

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

COMPOUND_OPERATORS: Map[String, String] = {
  "plus-assign": "plus",
  "minus-assign": "minus",
  "multiply-assign": "multiply",
  "divide-assign": "divide",
  "modulo-assign": "modulo",
}

# The C types an extern function may take, with their codes (Ast.Native) and the Agentica types the program sees. The
# integer types are the fixed widths and C.Long, the C long, 32 bits on Windows and 64 elsewhere (vm/ffi.c
# int_type_of); an unsigned 64-bit integer is a C.Int64. C.Function (code c, a C.Pointer to the program) is the address
# of a C function: as the first parameter the function the def calls, as the last (code e) the free function of the
# resource the call makes.
EXTERN_CODES = {
  "C.Int8": "g", "C.Int16": "h", "C.Int32": "i", "C.Int64": "l", "C.UInt8": "u", "C.UInt16": "w", "C.UInt32": "j",
  "C.Long": "n", "C.Double": "d", "C.Float": "f", "C.Bool": "b", "C.String": "s", "C.Pointer": "p", "C.Bytes": "y",
  "C.Function": "c",
}
EXTERN_TYPES = {
  "g": "Int", "h": "Int", "i": "Int", "l": "Int", "u": "Int", "w": "Int", "j": "Int", "n": "Int", "d": "Float",
  "f": "Float", "b": "Bool", "s": "String", "p": "C.Pointer", "v": "Void", "c": "C.Pointer", "e": "C.Pointer",
}
# The integer types named in the help texts.
INT_NAMES = "C.Int8, C.Int16, C.Int32, C.Int64, C.UInt8, C.UInt16, C.UInt32, C.Long"
EXTERN_TYPES_HELP = (
  "extern functions take and return #{INT_NAMES}, C.Double, C.Float, C.Bool, C.String, C.Pointer or a struct " +
  "or resource declared above in the same block, take C.Bytes or a C.Function, or return Void"
)
# The C types of a field of a struct of an extern block, with their codes; a field of a struct declared above in the
# block has that struct's layout code ("{" and the codes of its fields, then "}"), so a layout nests.
STRUCT_FIELD_CODES = {
  "C.Int8": "g", "C.Int16": "h", "C.Int32": "i", "C.Int64": "l", "C.UInt8": "u", "C.UInt16": "w", "C.UInt32": "j",
  "C.Long": "n", "C.Double": "d", "C.Float": "f", "C.Bool": "b", "C.Pointer": "p",
}
STRUCT_FIELD_HELP = (
  "a field of a C struct is #{INT_NAMES}, C.Double, C.Float, C.Bool, C.Pointer or a struct declared above in " +
  "the block; declare a char * field as C.Pointer and read the text with Native.get_string"
)
STRUCT_OUT_HELP = (
  "pass a struct that C fills as a C.Pointer to a buffer of Native.memory_pointer, and read its fields with " +
  "Native.get_*"
)
# The most fields of a C struct, nested ones counted, and the deepest nesting (STRUCT_MAX_FIELDS and STRUCT_MAX_DEPTH
# in vm/ffi.c).
STRUCT_MAX_FIELDS = 1024
STRUCT_MAX_DEPTH = 16
EXTERN_OUT_HELP = (
  "an out parameter is #{INT_NAMES}, C.Double, C.Float, C.Bool, C.Pointer or a resource of the block; " +
  "take a char ** or a function pointer as an out C.Pointer"
)
# The type name of a function pointer, and the free word of a resource whose values each have their own free function.
FUNCTION_TYPE = "C.Function"
FUNCTION_HELP = (
  "a C.Function parameter is first, the function the def calls, or last, the free function of the resource of a " +
  "free: C.Function kind that the call makes"
)
FUNCTION_RESULT_HELP = "declare a function that returns a function pointer -> C.Pointer"
# The help of a C type name that is not one, said in its place. C.Int was the name of C.Int32 before the widths became
# explicit; it is refused, with no alias. An unsigned type with no name of its own is the signed one of its width.
TYPE_NAME_HELP = {
  "C.Int": "write C.Int32 (a 32-bit int), C.Long (a long) or C.Int64 (a 64-bit integer) instead of C.Int",
  "C.UInt64": "write C.Int64: it carries the same 64 bits, and a value above 2^63 - 1 reads as negative",
  "C.ULong": "write C.Long: it carries the same bits, and a value above the largest long reads as negative",
}
## The help of a library that is not a name or an absolute path, in an extern block and in Native.load.
export EXTERN_LIBRARY_HELP = (
  "write a library name such as \"libm.so.6\" or an absolute path such as \"/usr/lib/libx.so\""
)
EXTERN_SYMBOL_HELP = "write the C name as a plain string of letters, digits and _, such as = \"fcntl\""
# The types that C's default argument promotions leave as they are, which the variadic part of an extern function
# takes: C.Bool, C.Int8, C.Int16, C.UInt8 and C.UInt16 (promoted to int) and C.Float (promoted to double) are not.
VARIADIC_CODES = Set.new(["i", "l", "j", "n", "d", "s", "p", "y", "r"])
# The code that marks where the variadic part starts in Ast.Native.codes.
VARIADIC_MARK = "."
DIGITS = Set.new("0123456789".split(""))
C_NAME_CHARS = Set.new("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789".split(""))
VARIADIC_HELP = (
  "after ... a parameter is C.Int32, C.Int64, C.UInt32, C.Long, C.Double, C.String, C.Pointer, C.Bytes or a " +
  "resource, and not an out parameter; pass a C.Bool or an integer narrower than an int there as C.Int32 and a " +
  "C.Float as C.Double"
)
# The most parameters an extern function takes (AGC_FFI_MAX_PARAMS in vm/ffi_os.h).
EXTERN_MAX_PARAMS = 64

# A declaration with the next position and the next free node id.
struct DeclAt
  node: Ast.Decl
  pos: Int
  ids: Int
end

struct DocAt
  doc: Ast.Optional[String]
  pos: Int
end

struct ImportNameAt
  node: Ast.ImportName
  pos: Int
end

struct ImportNamesAt
  nodes: List[Ast.ImportName]
  pos: Int
end

struct BlockParamsAt
  params: List[Ast.BlockParam]
  pos: Int
  ids: Int
end

struct NamedArgsAt
  nodes: List[Ast.NamedArg]
  pos: Int
  ids: Int
end

struct MapEntryAt
  node: Ast.MapEntry
  pos: Int
  ids: Int
end

struct IfBranchAt
  node: Ast.IfBranch
  pos: Int
  ids: Int
end

struct GuardAt
  node: Ast.Optional[Ast.Expr]
  pos: Int
  ids: Int
end

# The parameters, whether each is an `out` parameter of an extern function, the number of parameters before the `...`
# of a variadic extern function (-1 without one) and the position of that `...`, the next position and the next free
# id.
struct ParamsAt
  nodes: List[Ast.Param]
  outs: List[Bool]
  fixed: Int
  mark: Int
  pos: Int
  ids: Int
end

struct DeclsAt
  nodes: List[Ast.Decl]
  pos: Int
  ids: Int
end

# A type of an extern signature: its code, the type as the program sees it, and the next free node id.
struct ExternType
  code: String
  type: Ast.TypeRef
  ids: Int
end

# A member of an extern block and the block with it, and the record of a function with out parameters (none or one).
struct MemberAt
  decl: DeclAt
  block: ExternBlock
  records: List[Ast.Decl]
end

# A struct of an extern block and its layout code (ExternBlock.structs).
struct ExternStructAt
  decl: DeclAt
  layout: String
end

# An extern function, its C name ("" for a call through a function pointer) and its record (none or one), with the
# next position and the next free node id.
struct ExternAt
  decl: DeclAt
  symbol: String
  records: List[Ast.Decl]
end

# What the members of an extern block see of the block: its library, the free function of each resource declared so
# far, by name, the layout code of each struct declared so far, by name, the C names of the functions declared so far,
# and whether the block declares a resource or a struct anywhere (Ast.Native.with_types).
struct ExternBlock
  library: String
  resources: Map[String, String]
  structs: Map[String, String]
  symbols: Set[String]
  with_types: Bool
end

struct StructAt
  node: Ast.StructDecl
  pos: Int
  ids: Int
end

struct FieldAt
  node: Ast.FieldDecl
  pos: Int
  ids: Int
end

struct VariantAt
  node: Ast.EnumVariant
  pos: Int
  ids: Int
end

struct TypeParametersAt
  names: List[String]
  pos: Int
end

## Parses the tokens of the lexer into a Program, or returns the first PARSE- diagnostic. It stops at the first error
## and never fails otherwise. The nodes are numbered in post-order from first_id (see ast.agc), so that the modules of
## one program can share one numbering: start the next file at Ast.next_free_id(program).
export def parse(tokens: List[Tokens.Token], first_id: Int) -> Diag.Outcome[Ast.Program]
  case parse_program(Base.make_env(tokens), first_id)
    ok(program) -> return Diag.Outcome.Done(program)
    error(text) -> return Diag.Outcome.Failed(Base.unpack(text))
  end
end

## Whether the library of an extern block or of Native.load is a name the system loader searches for or an absolute
## path. A relative path would resolve against the working directory, while imports resolve against the source file:
## until a later phase decides, it is refused.
export def library_name?(name: String) -> Bool
  return name != "" and (!name.contains?("/") or name.starts_with?("/"))
end

def brace_help(form: String) -> String
  return "blocks have no braces: write \"#{form}\" ... \"end\""
end

# The newline that ends the head of a def, if, case, while or for. A `{` here gets the help that blocks have no braces.
def expect_head_end(e: Base.Env, pos: Int, description: String, form: String) -> Result[Int]
  if e.tokens[pos].kind == "left-brace"
    return error(
      Base.unexpected_help(
        e,
        pos,
        "expected #{description}, found #{Base.describe(e.tokens[pos])}",
        brace_help(form),
      ),
    )
  end

  return Base.expect(e, pos, "NL", description, false)
end

# Inside a do block body a statement may also end at `end` on the same line; the end is not consumed
# (expect_statement_end).
def statement_end?(e: Base.Env, pos: Int) -> Bool
  kind = e.tokens[pos].kind
  return kind == "NL" or (e.depth > 0 and kind == "end")
end

def expect_statement_end(e: Base.Env, pos: Int, description: String) -> Result[Int]
  token = e.tokens[pos]
  if token.kind == "if" or token.kind == "while"
    return error(
      Base.unexpected_help(
        e,
        pos,
        "expected a newline after the statement, found #{Base.describe(token)}",
        "there are no #{token.lexeme} modifiers: put the statement inside #{token.lexeme} cond ... end",
      ),
    )
  end

  if e.depth > 0 and token.kind == "end"
    return ok(pos)
  end

  return Base.expect(e, pos, "NL", description, false)
end

def expect_end(e: Base.Env, pos: Int) -> Result[Int]
  kind = e.tokens[pos].kind
  if kind == "end"
    return ok(pos + 1)
  end

  if kind == "EOF"
    return error(Base.bail(e, pos, "PARSE-UNCLOSED-BLOCK", "unclosed block, expected \"end\"", Diag.Help.NoHelp))
  end

  return error(Base.found(e, pos, "\"end\""))
end

def expr_at(node: Ast.Expr, pos: Int, ids: Int) -> Result[Base.ExprAt]
  return ok(Base.ExprAt(node: node, pos: pos, ids: ids + 1))
end

def call_node(
  e: Base.Env,
  start: Int,
  name: String,
  args: List[Ast.Expr],
  parenthesized: Bool,
  ids: Int,
  cursor: Int,
) -> Result[Base.ExprAt]
  node = Ast.Expr.Call(
    Ast.Call(
      id: ids,
      name: name,
      args: args,
      piped: false,
      parenthesized: parenthesized,
      span: Base.span_from(e, start, cursor),
    ),
  )
  return expr_at(node, cursor, ids)
end

# Ranges bind loosest and do not chain: a range is parsed here, over operands of level 1 and above.
# Every expression counts one level of nesting.
def parse_expression(e: Base.Env, pos: Int, ids: Int) -> Result[Base.ExprAt]
  inner = try Base.enter(e, pos)
  left = try parse_climb(inner, pos, ids, 1)
  kind = e.tokens[left.pos].kind
  if kind != "dot-dot" and kind != "dot-dot-dot"
    return ok(left)
  end

  right = try parse_climb(inner, left.pos + 1, left.ids, 1)
  after = e.tokens[right.pos].kind
  if after == "dot-dot" or after == "dot-dot-dot"
    return error(
      Base.unexpected_help(
        e,
        right.pos,
        "ranges do not chain, found #{Base.describe(e.tokens[right.pos])}",
        "wrap each range in parentheses: (a..b) == (c..d)",
      ),
    )
  end

  node = Ast.Expr.Binary(
    Ast.Binary(
      id: right.ids,
      op: kind,
      op_span: e.tokens[left.pos].span,
      left: left.node,
      right: right.node,
      span: Base.span_from(e, pos, right.pos),
    ),
  )
  return expr_at(node, right.pos, right.ids)
end

# x |> f(a) becomes the call f(x, a), keeping the id and span of the call written on the right, so the ids stay in
# post-order: x was parsed first and has smaller ids. A try on the right wraps the call. Only a call written with
# parentheses and not piped yet is a target; Absent gives PARSE-PIPE-TARGET.
def pipe_insert(left: Ast.Expr, node: Ast.Expr) -> Ast.Optional[Ast.Expr]
  case node
    Ast.Expr.Call(call) ->
      if call.piped or !call.parenthesized
        return Ast.Optional.Absent
      end

      return Ast.Optional.Present(
        Ast.Expr.Call(
          Ast.Call(
            id: call.id,
            name: call.name,
            args: List.concat([left], call.args),
            piped: true,
            parenthesized: false,
            span: call.span,
          ),
        ),
      )
    Ast.Expr.Try(wrapper) ->
      case wrapper.operand
        Ast.Expr.Call(call) ->
          if call.piped or !call.parenthesized
            return Ast.Optional.Absent
          end

          inserted = Ast.Expr.Call(
            Ast.Call(
              id: call.id,
              name: call.name,
              args: List.concat([left], call.args),
              piped: true,
              parenthesized: false,
              span: call.span,
            ),
          )
          return Ast.Optional.Present(Ast.Expr.Try(Ast.TryExpr(id: wrapper.id, operand: inserted, span: wrapper.span)))
        _ -> return Ast.Optional.Absent
      end

    _ -> return Ast.Optional.Absent
  end
end

def chained_message(level: Int) -> String
  if level == 3
    return "equality does not chain; combine two comparisons with \"and\""
  end

  return "comparison does not chain; write \"a < b and b < c\""
end

# Precedence climbing over the binary levels of level_of, the same grammar as the chain of parse-or ...
# One level of binary operators. It parses the operators of level minimum and above, left to right. The
# operand on the right of a level L operator is parsed with minimum L + 1, so operators of one level group to the left.
# Equality and comparison do not chain: a second operator of the same level is PARSE-CHAINED-COMPARISON at that
# operator. Every binary node starts at the first token of the whole expression, as the grammar says.
# Nesting limit: the first parser had one loop per level, and in each loop the right operand of the k-th operator
# starts from the nesting of the loop plus k. Here one loop serves all levels, so run counts the operators of the
# current level in a row (the levels never rise inside the loop, because the right operand of a level L operator takes
# everything above L) and operand_env is the context for the right operand. Equality and comparison do not chain, so
# they add nothing.
def parse_climb(e: Base.Env, pos: Int, ids: Int, minimum: Int) -> Result[Base.ExprAt]
  first = try parse_unary(e, pos, ids)
  left = first.node
  cursor = first.pos
  next_id = first.ids
  run = 0
  run_level = 0
  while true
    kind = e.tokens[cursor].kind
    level = LEVELS.get(kind, 0)
    if level == 0 or level < minimum
      return ok(Base.ExprAt(node: left, pos: cursor, ids: next_id))
    end

    operand_env = e
    if level != 3 and level != 4
      if level == run_level
        run += 1
      else
        run = 1
        run_level = level
      end

      operand_env = try Base.deepen(e, cursor, run)
    end

    if level == 5
      right_start = cursor + 1
      right = try parse_climb(operand_env, right_start, next_id, 6)
      case pipe_insert(left, right.node)
        Ast.Optional.Present(node) ->
          left = node
        Ast.Optional.Absent ->
          return error(
            Base.bail_span(
              "PARSE-PIPE-TARGET",
              "the right side of |> must be a call with parentheses, such as f() or Alias.f(a)",
              Base.span_from(e, right_start, right.pos),
              Base.hint("wrap the expression in parentheses and use . on the result, for example (x |> f()).unwrap!"),
            ),
          )
      end

      cursor = right.pos
      next_id = right.ids
    else
      right = try parse_climb(operand_env, cursor + 1, next_id, level + 1)
      following = LEVELS.get(e.tokens[right.pos].kind, 0)
      if following == level and (level == 3 or level == 4)
        return error(Base.bail(e, right.pos, "PARSE-CHAINED-COMPARISON", chained_message(level), Diag.Help.NoHelp))
      end

      left = Ast.Expr.Binary(
        Ast.Binary(
          id: right.ids,
          op: kind,
          op_span: e.tokens[cursor].span,
          left: left,
          right: right.node,
          span: Base.span_from(e, pos, right.pos),
        ),
      )
      cursor = right.pos
      next_id = right.ids + 1
    end
  end

  return error(Base.impossible(e, cursor))
end

# try, - and not nest, so each one counts a level.
def parse_unary(e: Base.Env, pos: Int, ids: Int) -> Result[Base.ExprAt]
  kind = e.tokens[pos].kind
  if kind == "try"
    inner = try Base.enter(e, pos)
    operand = try parse_unary(inner, pos + 1, ids)
    node = Ast.Expr.Try(Ast.TryExpr(id: operand.ids, operand: operand.node, span: Base.span_from(e, pos, operand.pos)))
    return expr_at(node, operand.pos, operand.ids)
  end

  if kind == "minus" or kind == "not"
    inner = try Base.enter(e, pos)
    operand = try parse_unary(inner, pos + 1, ids)
    node = Ast.Expr.Unary(
      Ast.Unary(
        id: operand.ids,
        op: kind,
        op_span: e.tokens[pos].span,
        operand: operand.node,
        span: Base.span_from(e, pos, operand.pos),
      ),
    )
    return expr_at(node, operand.pos, operand.ids)
  end

  return parse_postfix(e, pos, ids)
end

def block_target?(target: Ast.Expr) -> Bool
  case target
    Ast.Expr.Call(call) -> return true
    Ast.Expr.MethodCall(call) -> return true
    Ast.Expr.FieldAccess(access) -> return true
    _ -> return false
  end
end

def block_name_help(name: String) -> String
  if name == "lambda" or name == "proc"
    return "there are no standalone lambdas: pass a block to a call (xs.map do |x| ... end) or use &name"
  end

  if name == "loop"
    return "there is no loop; use while true ... end, or a while condition"
  end

  return "to call a function, add parentheses: #{name}() do ... end; an if condition ends with a newline, not do"
end

# `do` after a call, a method call or a field access adds a block as the last argument. The node built before is
# dropped, and it was the last one numbered, so its id is reused: the block is parsed from ids - 1 and the new node is
# numbered after the block, which keeps the ids dense and in post-order. A field access becomes a method call.
def attach_block(e: Base.Env, start: Int, target: Ast.Expr, cursor: Int, ids: Int) -> Result[Base.ExprAt]
  block = try parse_block_lit(e, cursor, ids - 1)
  span = Base.span_from(e, start, block.pos)
  case target
    Ast.Expr.Call(call) ->
      node = Ast.Expr.Call(
        Ast.Call(
          id: block.ids,
          name: call.name,
          args: call.args.push(block.node),
          piped: call.piped,
          parenthesized: call.parenthesized,
          span: span,
        ),
      )
      return expr_at(node, block.pos, block.ids)
    Ast.Expr.MethodCall(call) ->
      node = Ast.Expr.MethodCall(
        Ast.MethodCall(
          id: block.ids,
          target: call.target,
          name: call.name,
          name_span: call.name_span,
          args: call.args.push(block.node),
          span: span,
        ),
      )
      return expr_at(node, block.pos, block.ids)
    Ast.Expr.FieldAccess(access) ->
      node = Ast.Expr.MethodCall(
        Ast.MethodCall(
          id: block.ids,
          target: access.target,
          name: access.name,
          name_span: access.name_span,
          args: [block.node],
          span: span,
        ),
      )
      return expr_at(node, block.pos, block.ids)
    _ -> return error(Base.impossible(e, cursor))
  end
end

# A primary followed by .name, .name(args), [index] and `do` blocks. `.call(args)` is an Invoke of a function value. A
# `do` after a plain name is an error with a help text, except where blocks are not allowed (case, while and for
# headers). Each suffix is a link of the nesting limit: what follows the k-th suffix (arguments, index, block) is
# parsed k levels deeper.
def parse_postfix(e: Base.Env, pos: Int, ids: Int) -> Result[Base.ExprAt]
  first = try parse_primary(e, pos, ids)
  target = first.node
  cursor = first.pos
  next_id = first.ids
  links = 0
  while true
    kind = e.tokens[cursor].kind
    if kind == "dot"
      links += 1
      inner = try Base.deepen(e, cursor, links)
      after_name = try Base.expect(e, cursor + 1, "name", "a field or method name", true)
      name = e.tokens[cursor + 1].lexeme
      if e.tokens[after_name].kind == "left-paren" and name == "with"
        # `with` is only special before `(` after a dot; `x.with` still reads a field.
        args = try parse_update_arguments(inner, after_name + 1, next_id)
        close = try Base.expect(e, args.pos, "right-paren", "\")\"", false)
        target = Ast.Expr.Update(
          Ast.StructUpdate(
            id: args.ids,
            target: target,
            args: args.nodes,
            visible: Ast.Optional.Absent,
            span: Base.span_from(e, pos, close),
          ),
        )
        cursor = close
        next_id = args.ids + 1
      elsif e.tokens[after_name].kind == "left-paren"
        args = try parse_expression_list(inner, after_name + 1, next_id, "right-paren")
        close = try Base.expect(e, args.pos, "right-paren", "\")\"", false)
        span = Base.span_from(e, pos, close)
        if name == "call"
          target = Ast.Expr.Invoke(Ast.Invoke(id: args.ids, target: target, args: args.nodes, span: span))
        else
          target = Ast.Expr.MethodCall(
            Ast.MethodCall(
              id: args.ids,
              target: target,
              name: name,
              name_span: e.tokens[cursor + 1].span,
              args: args.nodes,
              span: span,
            ),
          )
        end

        cursor = close
        next_id = args.ids + 1
      else
        target = Ast.Expr.FieldAccess(
          Ast.FieldAccess(
            id: next_id,
            target: target,
            name: name,
            name_span: e.tokens[cursor + 1].span,
            span: Base.span_from(e, pos, after_name),
          ),
        )
        cursor = after_name
        next_id += 1
      end
    elsif kind == "left-bracket"
      links += 1
      inner = try Base.deepen(e, cursor, links)
      index = try parse_expression(Base.with_blocks(inner, true), cursor + 1, next_id)
      close = try Base.expect(e, index.pos, "right-bracket", "\"]\"", false)
      target = Ast.Expr.Index(
        Ast.IndexAccess(id: index.ids, target: target, index: index.node, span: Base.span_from(e, pos, close)),
      )
      cursor = close
      next_id = index.ids + 1
    elsif kind == "do" and e.allow_blocks and block_target?(target)
      links += 1
      inner = try Base.deepen(e, cursor, links)
      attached = try attach_block(inner, pos, target, cursor, next_id)
      target = attached.node
      cursor = attached.pos
      next_id = attached.ids
    elsif kind == "do" and e.allow_blocks and name_target?(target)
      return error(
        Base.unexpected_help(
          e,
          cursor,
          "a block needs a call before it, found the name \"#{target_name(target)}\"",
          block_name_help(target_name(target)),
        ),
      )
    else
      return ok(Base.ExprAt(node: target, pos: cursor, ids: next_id))
    end
  end

  return error(Base.impossible(e, cursor))
end

def name_target?(target: Ast.Expr) -> Bool
  case target
    Ast.Expr.Name(reference) -> return true
    _ -> return false
  end
end

def target_name(target: Ast.Expr) -> String
  case target
    Ast.Expr.Name(reference) -> return reference.name
    _ -> return ""
  end
end

# The parameters of a do block, after the first |, up to and including the closing |.
def parse_block_params(e: Base.Env, pos: Int, ids: Int) -> Result[BlockParamsAt]
  params: List[Ast.BlockParam] = []
  cursor = pos
  next_id = ids
  looping = true
  while looping
    after = try Base.expect(e, cursor, "name", "a block parameter name", false)
    name_pos = cursor
    cursor = after
    type: Ast.Optional[Ast.TypeRef] = Ast.Optional.Absent
    if e.tokens[cursor].kind == "colon"
      parsed = try Base.parse_type(e, cursor + 1, next_id)
      type = Ast.Optional.Present(parsed.node)
      cursor = parsed.pos
      next_id = parsed.ids
    end

    params = params.push(
      Ast.BlockParam(
        id: next_id,
        name: e.tokens[name_pos].lexeme,
        name_span: e.tokens[name_pos].span,
        type: type,
        span: Base.span_from(e, name_pos, cursor),
      ),
    )
    next_id += 1
    if e.tokens[cursor].kind == "comma"
      cursor += 1
    else
      cursor = try Base.expect(e, cursor, "pipe", "\"|\" after the block parameters", false)
      looping = false
    end
  end

  return ok(BlockParamsAt(params: params, pos: cursor, ids: next_id))
end

# do |params| body end. The body allows blocks again and is a block body (depth 1), where `end` may follow a statement
# on the same line.
def parse_block_lit(e: Base.Env, pos: Int, ids: Int) -> Result[Base.ExprAt]
  cursor = pos + 1
  if e.tokens[cursor].kind == "or"
    return error(Base.unexpected(e, cursor, "a block without parameters has no bars; write do ... end"))
  end

  params: List[Ast.BlockParam] = []
  next_id = ids
  if e.tokens[cursor].kind == "pipe"
    parsed = try parse_block_params(e, cursor + 1, next_id)
    params = parsed.params
    cursor = parsed.pos
    next_id = parsed.ids
  end

  brace_at = -1
  form = ""
  if e.tokens[cursor].kind == "left-brace"
    brace_at = cursor
    form = "do"
    if params.size > 0
      names = params.map do |param| param.name end
      form = "do |#{names.join(", ")}|"
    end
  end

  body = try parse_block(Base.with_block_body(e, brace_at, form), cursor, next_id, 1)
  close = try expect_end(e, body.pos)
  node = Ast.Expr.BlockLit(
    Ast.BlockLit(id: body.ids, params: params, body: body.nodes, span: Base.span_from(e, pos, close)),
  )
  return expr_at(node, close, body.ids)
end

def parse_expression_list(e: Base.Env, pos: Int, ids: Int, terminator: String) -> Result[Base.ExprsAt]
  nodes: List[Ast.Expr] = []
  if e.tokens[pos].kind == terminator
    return ok(Base.ExprsAt(nodes: nodes, pos: pos, ids: ids))
  end

  inner = Base.with_blocks(e, true)
  cursor = pos
  next_id = ids
  looping = true
  while looping
    parsed = try parse_expression(inner, cursor, next_id)
    nodes = nodes.push(parsed.node)
    cursor = parsed.pos
    next_id = parsed.ids
    if e.tokens[cursor].kind == "comma"
      cursor += 1
      if e.tokens[cursor].kind == terminator
        looping = false
      end
    else
      looping = false
    end
  end

  return ok(Base.ExprsAt(nodes: nodes, pos: cursor, ids: next_id))
end

def parse_named_arguments(e: Base.Env, pos: Int, ids: Int) -> Result[NamedArgsAt]
  nodes: List[Ast.NamedArg] = []
  if e.tokens[pos].kind == "right-paren"
    return ok(NamedArgsAt(nodes: nodes, pos: pos, ids: ids))
  end

  cursor = pos
  next_id = ids
  looping = true
  while looping
    after = try Base.expect(e, cursor, "name", "a field name", false)
    colon = try Base.expect(e, after, "colon", "\":\"", false)
    value = try parse_expression(e, colon, next_id)
    nodes = nodes.push(
      Ast.NamedArg(
        id: value.ids,
        name: e.tokens[cursor].lexeme,
        value: value.node,
        span: Base.span_from(e, cursor, value.pos),
      ),
    )
    cursor = value.pos
    next_id = value.ids + 1
    if e.tokens[cursor].kind == "comma"
      cursor += 1
      if e.tokens[cursor].kind == "right-paren"
        looping = false
      end
    else
      looping = false
    end
  end

  return ok(NamedArgsAt(nodes: nodes, pos: cursor, ids: next_id))
end

# The arguments of `.with(`: one or more name: value pairs, with `do` blocks allowed as in any call. A positional value
# or an empty list gets a help text, since the parser cannot know which field was meant.
def parse_update_arguments(e: Base.Env, pos: Int, ids: Int) -> Result[NamedArgsAt]
  inner = Base.with_blocks(e, true)
  nodes: List[Ast.NamedArg] = []
  cursor = pos
  next_id = ids
  looping = true
  while looping
    colon = try expect_update_argument(inner, cursor)
    value = try parse_expression(inner, colon, next_id)
    nodes = nodes.push(
      Ast.NamedArg(
        id: value.ids,
        name: inner.tokens[cursor].lexeme,
        value: value.node,
        span: Base.span_from(inner, cursor, value.pos),
      ),
    )
    cursor = value.pos
    next_id = value.ids + 1
    if inner.tokens[cursor].kind == "comma"
      cursor += 1
      if inner.tokens[cursor].kind == "right-paren"
        looping = false
      end
    else
      looping = false
    end
  end

  return ok(NamedArgsAt(nodes: nodes, pos: cursor, ids: next_id))
end

# The position of the value after `name:` at pos; PARSE-UNEXPECTED-TOKEN with a help text for anything else.
def expect_update_argument(e: Base.Env, pos: Int) -> Result[Int]
  named = Base.plain_name?(e.tokens[pos])
  if named and Base.kind_at(e, pos + 1) == "colon"
    return ok(pos + 2)
  end

  help = "name each field to change, as in value.with(age: 31)"
  if named
    return error(
      Base.unexpected_help(
        e,
        pos + 1,
        "expected \":\" after the field name, found #{Base.describe(e.tokens[pos + 1])}",
        help,
      ),
    )
  end

  return error(Base.unexpected_help(e, pos, "expected a field name, found #{Base.describe(e.tokens[pos])}", help))
end

def parse_list_literal(e: Base.Env, pos: Int, ids: Int) -> Result[Base.ExprAt]
  elements = try parse_expression_list(e, pos + 1, ids, "right-bracket")
  close = try Base.expect(e, elements.pos, "right-bracket", "\"]\"", false)
  node = Ast.Expr.ListLit(Ast.ListLit(id: elements.ids, elements: elements.nodes, span: Base.span_from(e, pos, close)))
  return expr_at(node, close, elements.ids)
end

def parse_map_entry(e: Base.Env, pos: Int, ids: Int, block_form: String) -> Result[MapEntryAt]
  key = try parse_expression(e, pos, ids)
  if e.tokens[key.pos].kind != "colon" and block_form != ""
    return error(
      Base.unexpected_help(
        e,
        key.pos,
        "expected \":\", found #{Base.describe(e.tokens[key.pos])}",
        "if \"{\" opens the block: blocks have no braces, write \"#{block_form}\" ... \"end\"",
      ),
    )
  end

  colon = try Base.expect(e, key.pos, "colon", "\":\"", false)
  value = try parse_expression(e, colon, key.ids)
  node = Ast.MapEntry(id: value.ids, key: key.node, value: value.node, span: Base.span_from(e, pos, value.pos))
  return ok(MapEntryAt(node: node, pos: value.pos, ids: value.ids + 1))
end

def parse_map_literal(e: Base.Env, pos: Int, ids: Int) -> Result[Base.ExprAt]
  block_form = ""
  if e.brace_at == pos
    block_form = e.brace_form
  end

  entries: List[Ast.MapEntry] = []
  cursor = pos + 1
  next_id = ids
  if e.tokens[cursor].kind != "right-brace"
    first = try parse_map_entry(e, cursor, next_id, block_form)
    entries = entries.push(first.node)
    cursor = first.pos
    next_id = first.ids
    looping = true
    while looping and e.tokens[cursor].kind == "comma"
      cursor += 1
      if e.tokens[cursor].kind == "right-brace"
        looping = false
      else
        more = try parse_map_entry(e, cursor, next_id, "")
        entries = entries.push(more.node)
        cursor = more.pos
        next_id = more.ids
      end
    end
  end

  close = try Base.expect(e, cursor, "right-brace", "\"}\"", false)
  node = Ast.Expr.MapLit(Ast.MapLit(id: next_id, entries: entries, span: Base.span_from(e, pos, close)))
  return expr_at(node, close, next_id)
end

# The parts of "a#{x}b" arrive as one string token, then expressions and string tokens in turn; empty text parts are
# dropped.
def parse_interpolation(e: Base.Env, pos: Int, ids: Int) -> Result[Base.ExprAt]
  parts: List[Ast.Part] = []
  opening = Base.token_text(e.tokens[pos])
  if opening != ""
    parts = parts.push(Ast.Part.Text(opening))
  end

  cursor = pos + 1
  next_id = ids
  while true
    parsed = try parse_expression(e, cursor, next_id)
    parts = parts.push(Ast.Part.Code(parsed.node))
    next_id = parsed.ids
    piece = e.tokens[parsed.pos]
    text = Base.token_text(piece)
    if piece.kind == "interp-middle" or piece.kind == "interp-end"
      if text != ""
        parts = parts.push(Ast.Part.Text(text))
      end

      cursor = parsed.pos + 1
      if piece.kind == "interp-end"
        node = Ast.Expr.Interpolation(
          Ast.Interpolation(id: next_id, parts: parts, span: Base.span_from(e, pos, cursor)),
        )
        return expr_at(node, cursor, next_id)
      end
    else
      return error(
        Base.unexpected(e, parsed.pos, "expected \"}\" to close the interpolation, found #{Base.describe(piece)}"),
      )
    end
  end

  return error(Base.impossible(e, cursor))
end

def literal_node(token: Tokens.Token, value: Ast.LitValue, ids: Int) -> Ast.Expr
  return Ast.Expr.Literal(Ast.Literal(id: ids, value: value, span: token.span))
end

def parse_function_ref(e: Base.Env, pos: Int, ids: Int) -> Result[Base.ExprAt]
  cursor = pos + 1
  name = ""
  if e.tokens[cursor].kind == "type-name"
    dot = try Base.expect(e, cursor + 1, "dot", "a dot", false)
    stop = try Base.expect(e, dot, "name", "a function name", true)
    name = "#{e.tokens[cursor].lexeme}.#{e.tokens[dot].lexeme}"
    cursor = stop
  else
    stop = try Base.expect(e, cursor, "name", "a function name", true)
    name = e.tokens[cursor].lexeme
    cursor = stop
  end

  node = Ast.Expr.FunctionRef(Ast.FunctionRef(id: ids, name: name, span: Base.span_from(e, pos, cursor)))
  return expr_at(node, cursor, ids)
end

def lambda_name?(lexeme: String) -> Bool
  return lexeme == "fn" or lexeme == "func" or lexeme == "function" or lexeme == "lambda" or lexeme == "proc"
end

# A name, a call name(args), or the bare calls gets and gets!. fn(x: Int), lambda(x: Int) and the like are an error
# with help: there are no lambdas.
def parse_name_primary(e: Base.Env, pos: Int, ids: Int) -> Result[Base.ExprAt]
  token = e.tokens[pos]
  paren = pos + 1
  if (
    lambda_name?(token.lexeme) and
    e.tokens[paren].kind == "left-paren" and
    Base.kind_at(e, paren + 1) == "name" and
    Base.kind_at(e, paren + 2) == "colon"
  )
    return error(
      Base.unexpected_help(
        e,
        pos,
        "there are no standalone lambdas",
        "pass a block to a call (xs.map do |x: Int| ... end), or declare a function with def and use &name",
      ),
    )
  end

  if e.tokens[paren].kind == "left-paren"
    args = try parse_expression_list(e, paren + 1, ids, "right-paren")
    close = try Base.expect(e, args.pos, "right-paren", "\")\"", false)
    return call_node(e, pos, token.lexeme, args.nodes, true, args.ids, close)
  end

  if token.lexeme == "gets" or token.lexeme == "gets!"
    no_args: List[Ast.Expr] = []
    node = Ast.Expr.Call(
      Ast.Call(id: ids, name: token.lexeme, args: no_args, piped: false, parenthesized: false, span: token.span),
    )
    return expr_at(node, paren, ids)
  end

  return expr_at(Ast.Expr.Name(Ast.NameRef(id: ids, name: token.lexeme, span: token.span)), paren, ids)
end

def parenthesized_arguments(e: Base.Env, pos: Int, ids: Int) -> Result[Base.ExprsAt]
  args = try parse_expression_list(e, pos + 1, ids, "right-paren")
  close = try Base.expect(e, args.pos, "right-paren", "\")\"", false)
  return ok(Base.ExprsAt(nodes: args.nodes, pos: close, ids: args.ids))
end

def construct_node(
  e: Base.Env,
  start: Int,
  name: String,
  args: List[Ast.NamedArg],
  ids: Int,
  cursor: Int,
) -> Result[Base.ExprAt]
  node = Ast.Expr.Construct(
    Ast.Construct(id: ids, type_name: name, args: args, span: Base.span_from(e, start, cursor)),
  )
  return expr_at(node, cursor, ids)
end

def enum_constructor_node(
  e: Base.Env,
  start: Int,
  enum_name: String,
  variant_name: String,
  args: Base.ExprsAt,
  cursor: Int,
) -> Result[Base.ExprAt]
  node = Ast.Expr.EnumConstructor(
    Ast.EnumConstructor(
      id: args.ids,
      enum_name: enum_name,
      variant_name: variant_name,
      args: args.nodes,
      named: [],
      span: Base.span_from(e, start, cursor),
    ),
  )
  return expr_at(node, cursor, args.ids)
end

# After Type.Name: an enum constructor (A.B.C, A.B(args)), Result.Ok(x) and Result.Err(m), which are the calls ok and
# error, a struct construction through a module alias (A.B(name: v)), or a type name (also a constant through an alias,
# A.NAME, which the linker tells from a type).
def parse_qualified_member(e: Base.Env, pos: Int, ids: Int) -> Result[Base.ExprAt]
  name = e.tokens[pos].lexeme
  member_pos = pos + 2
  member = e.tokens[member_pos].lexeme
  qualified = "#{name}.#{member}"
  cursor = member_pos + 1
  kind = e.tokens[cursor].kind
  no_args: List[Ast.Expr] = []
  if kind == "dot" and Base.kind_at(e, cursor + 1) == "name"
    # Alias.NAME.x on an exported constant, or Enum.Variant.x: the postfix loop reads the field or method; the linker
    # decides what A.B is. A type-name after the dot is a variant (Alias.Enum.Variant).
    return expr_at(
      Ast.Expr.TypeName(Ast.TypeName(id: ids, name: qualified, span: Base.span_from(e, pos, cursor))),
      cursor,
      ids,
    )
  end

  if kind == "dot"
    variant_pos = cursor + 1
    after_variant = try Base.expect(e, variant_pos, "type-name", "an enum variant", false)
    args = Base.ExprsAt(nodes: no_args, pos: after_variant, ids: ids)
    if e.tokens[after_variant].kind == "left-paren"
      args = try parenthesized_arguments(e, after_variant, ids)
    end

    return enum_constructor_node(e, pos, qualified, e.tokens[variant_pos].lexeme, args, args.pos)
  end

  if kind == "left-paren" and name == "Result" and (member == "Ok" or member == "Err")
    args = try parenthesized_arguments(e, cursor, ids)
    helper = "error"
    if member == "Ok"
      helper = "ok"
    end

    return call_node(e, pos, helper, args.nodes, true, args.ids, args.pos)
  end

  if kind == "left-paren"
    inside = cursor + 1
    if e.tokens[inside].kind == "right-paren"
      no_named: List[Ast.NamedArg] = []
      return construct_node(e, pos, qualified, no_named, ids, inside + 1)
    end

    if e.tokens[inside].kind == "name" and Base.kind_at(e, inside + 1) == "colon"
      named = try parse_named_arguments(e, inside, ids)
      close = try Base.expect(e, named.pos, "right-paren", "\")\"", false)
      return construct_node(e, pos, qualified, named.nodes, named.ids, close)
    end

    args = try parenthesized_arguments(e, cursor, ids)
    return enum_constructor_node(e, pos, name, member, args, args.pos)
  end

  return expr_at(
    Ast.Expr.TypeName(Ast.TypeName(id: ids, name: qualified, span: Base.span_from(e, pos, cursor))),
    cursor,
    ids,
  )
end

# After Alias.name or Type.name: a module function call, with or without parentheses. A call without them may not be
# followed by an argument.
def parse_module_call(e: Base.Env, pos: Int, ids: Int) -> Result[Base.ExprAt]
  name = e.tokens[pos].lexeme
  member_pos = pos + 2
  after_member = try Base.expect(e, member_pos, "name", "a function name", true)
  member = e.tokens[member_pos]
  parenthesized = e.tokens[after_member].kind == "left-paren"
  args = Base.ExprsAt(nodes: [], pos: after_member, ids: ids)
  cursor = after_member
  if parenthesized
    args = try parenthesized_arguments(e, after_member, ids)
    cursor = args.pos
  else
    following = e.tokens[after_member].kind
    if (
      following == "name" or
      following == "type-name" or
      following == "integer" or
      following == "float" or
      following == "string" or
      following == "interp-start" or
      following == "left-bracket"
    )
      return error(
        Base.unexpected_help(
          e,
          after_member,
          "expected \"(\" or the end of the call, found #{Base.describe(e.tokens[after_member])}",
          "calls need parentheses, as in #{name}.#{member.lexeme}(...)",
        ),
      )
    end
  end

  return call_node(e, pos, "#{name}.#{member.lexeme}", args.nodes, parenthesized, args.ids, cursor)
end

# NAME.with(field: x) updates a constant of a struct type: the postfix loop reads the .with. A call has no named
# arguments, so field: after the parenthesis tells it from Alias.with(1), a call of a function called with through an
# alias written in capitals; the linker decides the rest.
def updates_constant?(e: Base.Env, name: Tokens.Token, dot: Int) -> Bool
  member = e.tokens[dot + 1]
  if member.kind != "name" or member.lexeme != "with" or e.tokens[dot + 2].kind != "left-paren"
    return false
  end

  return e.tokens[dot + 3].kind == "name" and e.tokens[dot + 4].kind == "colon" and Base.constant_name?(name.lexeme)
end

def parse_construct(e: Base.Env, pos: Int, ids: Int) -> Result[Base.ExprAt]
  name = e.tokens[pos]
  after = pos + 1
  if e.tokens[after].kind == "left-paren"
    named = try parse_named_arguments(e, after + 1, ids)
    close = try Base.expect(e, named.pos, "right-paren", "\")\"", false)
    return construct_node(e, pos, name.lexeme, named.nodes, named.ids, close)
  end

  if e.tokens[after].kind == "dot"
    if updates_constant?(e, name, after)
      return expr_at(Ast.Expr.TypeName(Ast.TypeName(id: ids, name: name.lexeme, span: name.span)), after, ids)
    end

    if e.tokens[after + 1].kind == "type-name"
      return parse_qualified_member(e, pos, ids)
    end

    return parse_module_call(e, pos, ids)
  end

  return expr_at(Ast.Expr.TypeName(Ast.TypeName(id: ids, name: name.lexeme, span: name.span)), after, ids)
end

# A call keeps parenthesized: |> accepts only calls that were written with parentheses.
def parse_primary(e: Base.Env, pos: Int, ids: Int) -> Result[Base.ExprAt]
  token = e.tokens[pos]
  kind = token.kind
  if kind == "name"
    return parse_name_primary(e, pos, ids)
  end

  if kind == "integer" or kind == "float" or kind == "string"
    return expr_at(literal_node(token, Base.literal_value(token), ids), pos + 1, ids)
  end

  if kind == "left-paren"
    inner = try parse_expression(Base.with_blocks(e, true), pos + 1, ids)
    close = try Base.expect(e, inner.pos, "right-paren", "\")\"", false)
    return ok(Base.ExprAt(node: inner.node, pos: close, ids: inner.ids))
  end

  if kind == "type-name"
    return parse_construct(e, pos, ids)
  end

  if kind == "interp-start"
    return parse_interpolation(e, pos, ids)
  end

  if kind == "true" or kind == "false"
    return expr_at(literal_node(token, Ast.LitValue.Flag(kind == "true"), ids), pos + 1, ids)
  end

  if kind == "nil"
    return expr_at(literal_node(token, Ast.LitValue.Nothing, ids), pos + 1, ids)
  end

  if kind == "ampersand"
    return parse_function_ref(e, pos, ids)
  end

  if kind == "left-bracket"
    return parse_list_literal(e, pos, ids)
  end

  if kind == "left-brace"
    return parse_map_literal(e, pos, ids)
  end

  return error(
    Base.bail(
      e,
      pos,
      "PARSE-UNEXPECTED-TOKEN",
      "expected an expression, found #{Base.describe(token)}",
      primary_help(e, pos),
    ),
  )
end

def adjacent?(first: Tokens.Token, second: Tokens.Token) -> Bool
  return first.span.stop.offset == second.span.start.offset
end

# Help for a / or * where an expression should start: // and /* */ are not comments in Agentica. Also for the second <
# of <<, Ruby's push.
def primary_help(e: Base.Env, pos: Int) -> Diag.Help
  token = e.tokens[pos]
  if token.kind == "do"
    return Base.hint("a block must follow a call, as in xs.map do |x| ... end; there are no standalone lambdas")
  end

  if token.kind == "less" and pos > 0 and e.tokens[pos - 1].kind == "less" and adjacent?(e.tokens[pos - 1], token)
    return Base.hint("there is no << operator; add to a list with xs = xs.push(x)")
  end

  if token.kind == "dot" and Base.kind_at(e, pos + 1) == "name" and pos > 0 and e.tokens[pos - 1].kind == "NL"
    return Base.hint(
      "a line that starts with .name continues the expression on the line above, which must end in a value; " +
      "a blank line ends it",
    )
  end

  if token.kind != "divide" and token.kind != "multiply"
    return Diag.Help.NoHelp
  end

  before = ""
  if pos > 0 and adjacent?(e.tokens[pos - 1], token)
    before = e.tokens[pos - 1].kind
  end

  after = ""
  if pos + 1 < e.size and adjacent?(token, e.tokens[pos + 1])
    after = e.tokens[pos + 1].kind
  end

  if token.kind == "divide" and before == "divide"
    return Base.hint(
      "comments start with #, not //; there is no // operator, and / on two Ints already truncates toward zero",
    )
  end

  if token.kind == "divide" and after == "divide"
    return Base.hint("comments start with #, not //")
  end

  if (token.kind == "divide" and after == "multiply") or (token.kind == "multiply" and before == "divide")
    return Base.hint("comments start with #, not /* */")
  end

  return Diag.Help.NoHelp
end

def stmt_at(node: Ast.Stmt, pos: Int, ids: Int) -> Result[Base.StmtAt]
  return ok(Base.StmtAt(node: node, pos: pos, ids: ids + 1))
end

# Statements up to end, elsif, else or the end of the file. depth is the block depth of the body (0, or 1 in a do
# block).
def parse_block(e: Base.Env, pos: Int, ids: Int, depth: Int) -> Result[Base.StmtsAt]
  inner = Base.with_depth(e, depth)
  nodes: List[Ast.Stmt] = []
  cursor = pos
  next_id = ids
  looping = true
  while looping
    cursor = Base.skip_newlines(e, cursor)
    kind = e.tokens[cursor].kind
    if kind == "end" or kind == "elsif" or kind == "else" or kind == "EOF"
      looping = false
    else
      parsed = try parse_statement(inner, cursor, next_id)
      nodes = nodes.push(parsed.node)
      cursor = parsed.pos
      next_id = parsed.ids
    end
  end

  return ok(Base.StmtsAt(nodes: nodes, pos: cursor, ids: next_id))
end

# Every statement counts a level of nesting.
def parse_statement(e: Base.Env, pos: Int, ids: Int) -> Result[Base.StmtAt]
  inner = try Base.enter(e, pos)
  kind = e.tokens[pos].kind
  if (
    kind == "name" and
    e.tokens[pos].lexeme == "type" and
    Base.kind_at(e, pos + 1) == "type-name" and
    Base.kind_at(e, pos + 2) == "assign"
  )
    return error(
      Base.bail(
        e,
        pos,
        "PARSE-TOP-LEVEL-STATEMENT",
        "type aliases are only allowed at the top level",
        Diag.Help.NoHelp,
      ),
    )
  end

  if kind == "if"
    return parse_if(inner, pos, ids)
  end

  if kind == "while"
    return parse_while(inner, pos, ids)
  end

  if kind == "for"
    return parse_for(inner, pos, ids)
  end

  if kind == "case"
    return parse_case(inner, pos, ids)
  end

  return parse_simple_statement(inner, pos, ids)
end

def parse_return(e: Base.Env, pos: Int, ids: Int) -> Result[Base.StmtAt]
  cursor = pos + 1
  next_id = ids
  value: Ast.Optional[Ast.Expr] = Ast.Optional.Absent
  if !statement_end?(e, cursor)
    parsed = try parse_expression(e, cursor, ids)
    value = Ast.Optional.Present(parsed.node)
    cursor = parsed.pos
    next_id = parsed.ids
  end

  stop = try expect_statement_end(e, cursor, "a newline after the statement")
  return stmt_at(
    Ast.Stmt.Return(Ast.Return(id: next_id, value: value, span: Base.span_from(e, pos, stop))),
    stop,
    next_id,
  )
end

def parse_loop_control(e: Base.Env, pos: Int, ids: Int) -> Result[Base.StmtAt]
  stop = try expect_statement_end(e, pos + 1, "a newline after the statement")
  return stmt_at(
    Ast.Stmt.Control(Ast.LoopControl(id: ids, kind: e.tokens[pos].lexeme, span: e.tokens[pos].span)),
    stop,
    ids,
  )
end

def parse_binding(e: Base.Env, pos: Int, ids: Int) -> Result[Base.StmtAt]
  cursor = try Base.expect(e, pos, "name", "a name", false)
  type: Ast.Optional[Ast.TypeRef] = Ast.Optional.Absent
  next_id = ids
  if e.tokens[cursor].kind == "colon"
    if e.tokens[pos].lexeme == "_"
      return error(
        Base.unexpected_help(
          e,
          cursor,
          "a discard \"_\" has no type to declare",
          "write _ = value",
        ),
      )
    end

    parsed = try Base.parse_type(e, cursor + 1, next_id)
    type = Ast.Optional.Present(parsed.node)
    cursor = parsed.pos
    next_id = parsed.ids
  end

  assign = try Base.expect(e, cursor, "assign", "\"=\"", false)
  value = try parse_expression(e, assign, next_id)
  stop = try expect_statement_end(e, value.pos, "a newline after the statement")
  node = Ast.Stmt.Binding(
    Ast.Binding(
      id: value.ids,
      name: e.tokens[pos].lexeme,
      name_span: e.tokens[pos].span,
      type: type,
      value: value.node,
      span: Base.span_from(e, pos, stop),
    ),
  )
  return stmt_at(node, stop, value.ids)
end

# x += v is the binding x = x + v. The name node is numbered first so the ids stay in post-order: it is the left child
# of the binary node.
def parse_compound(e: Base.Env, pos: Int, ids: Int) -> Result[Base.StmtAt]
  # A name ending in ? or ! is not a variable, so `foo? += 1` fails here.
  after_name = try Base.expect(e, pos, "name", "a name", false)
  operator = e.tokens[pos + 1]
  target = Ast.Expr.Name(Ast.NameRef(id: ids, name: e.tokens[pos].lexeme, span: e.tokens[pos].span))
  value = try parse_expression(e, pos + 2, ids + 1)
  stop = try expect_statement_end(e, value.pos, "a newline after the statement")
  span = Base.span_from(e, pos, stop)
  combined = Ast.Expr.Binary(
    Ast.Binary(
      id: value.ids,
      op: COMPOUND_OPERATORS.get(operator.kind, ""),
      op_span: operator.span,
      left: target,
      right: value.node,
      span: span,
    ),
  )
  node = Ast.Stmt.Binding(
    Ast.Binding(
      id: value.ids + 1,
      name: e.tokens[pos].lexeme,
      name_span: e.tokens[pos].span,
      type: Ast.Optional.Absent,
      value: combined,
      span: span,
    ),
  )
  return stmt_at(node, stop, value.ids + 1)
end

def assignment_message(node: Ast.Expr) -> String
  case node
    Ast.Expr.Index(access) -> return (
      "the core only assigns to a plain name; lists and maps are immutable, build a new value instead (for a map, " +
      "Map.put(map, key, value))"
    )
    _ -> return "the core only assigns to a plain name"
  end
end

# A constant written as the target of an assignment inside a function.
def assignment_help(node: Ast.Expr) -> Diag.Help
  case node
    Ast.Expr.TypeName(found) ->
      if Base.constant_name?(found.name)
        return Base.hint("constants are set at the top level and never change")
      end

      return Diag.Help.NoHelp
    _ -> return Diag.Help.NoHelp
  end
end

def keyword_message(name: String) -> String
  if name == "break" or name == "next"
    return "\"#{name}\" stands alone on its line"
  end

  return "\"#{name}\" is not a keyword"
end

def keyword_help(name: String) -> String
  case name
    "match" -> return "use case value, then arms pattern -> ..., then end"
    "break" -> return (
      "#{name} stands alone on its line; there are no if modifiers: write if cond, then #{name}, then end"
    )
    "next" -> return (
      "#{name} stands alone on its line; there are no if modifiers: write if cond, then #{name}, then end"
    )
    "continue" -> return "write next to skip to the next iteration"
    _ -> return "write x = 5, or x: Int = 5 to give a type"
  end
end

def foreign_keyword?(name: String) -> Bool
  return (
    name == "let" or
    name == "var" or
    name == "val" or
    name == "const" or
    name == "match" or
    name == "break" or
    name == "continue" or
    name == "next"
  )
end

# An expression statement. These stops are copied on purpose: an assignment target that is not a name, elif and elseif
# written as names, and a foreign keyword (let, var, match, ...) or a call without parentheses before the end of the
# line, each with its own message.
def parse_expression_statement(e: Base.Env, pos: Int, ids: Int) -> Result[Base.StmtAt]
  value = try parse_expression(e, pos, ids)
  following = e.tokens[value.pos].kind
  if following == "assign" or COMPOUND_OPERATORS.get(following, "") != ""
    return error(
      Base.bail(
        e,
        value.pos,
        "PARSE-INVALID-ASSIGNMENT-TARGET",
        assignment_message(value.node),
        assignment_help(value.node),
      ),
    )
  end

  if name_target?(value.node)
    name = target_name(value.node)
    if name == "elif" or name == "elseif"
      return error(
        Base.unexpected_help(
          e,
          pos,
          "\"#{name}\" is not a keyword",
          "write elsif: if a ... elsif b ... else ... end",
        ),
      )
    end

    if !statement_end?(e, value.pos)
      if foreign_keyword?(name)
        return error(Base.unexpected_help(e, pos, keyword_message(name), keyword_help(name)))
      end

      return error(
        Base.unexpected(
          e,
          value.pos,
          "expected a newline after the statement; calls need parentheses, as in #{name}(...)",
        ),
      )
    end
  end

  stop = try expect_statement_end(e, value.pos, "a newline after the statement")
  return stmt_at(
    Ast.Stmt.Expression(Ast.ExprStmt(id: value.ids, value: value.node, span: Base.span_from(e, pos, stop))),
    stop,
    value.ids,
  )
end

# return, break and next, bindings and compound assignments are told apart by one token of lookahead; anything else is
# an expression.
def parse_simple_statement(e: Base.Env, pos: Int, ids: Int) -> Result[Base.StmtAt]
  token = e.tokens[pos]
  if token.kind == "return"
    return parse_return(e, pos, ids)
  end

  if token.kind == "name"
    following = Base.kind_at(e, pos + 1)
    if (
      (token.lexeme == "break" or token.lexeme == "next") and
      (following == "NL" or following == "end" or following == "EOF")
    )
      return parse_loop_control(e, pos, ids)
    end

    if following == "assign" or following == "colon"
      return parse_binding(e, pos, ids)
    end

    if COMPOUND_OPERATORS.get(following, "") != ""
      return parse_compound(e, pos, ids)
    end
  end

  return parse_expression_statement(e, pos, ids)
end

def parse_if_branch(e: Base.Env, pos: Int, ids: Int) -> Result[IfBranchAt]
  condition = try parse_expression(e, pos + 1, ids)
  following = e.tokens[condition.pos]
  if following.kind == "name" and following.lexeme == "then"
    return error(
      Base.unexpected_help(
        e,
        condition.pos,
        "expected a newline after the condition, found \"then\"",
        "there is no then: end the condition with a newline",
      ),
    )
  end

  if following.kind == "do"
    return error(
      Base.unexpected_help(
        e,
        condition.pos,
        "expected a newline after the condition, found do",
        "an if condition ends with a newline, not do",
      ),
    )
  end

  head = try expect_head_end(e, condition.pos, "a newline after the condition", "#{e.tokens[pos].lexeme} cond")
  body = try parse_block(e, head, condition.ids, 0)
  node = Ast.IfBranch(
    id: body.ids,
    condition: condition.node,
    body: body.nodes,
    span: Base.span_from(e, pos, body.pos),
  )
  return ok(IfBranchAt(node: node, pos: body.pos, ids: body.ids + 1))
end

def parse_if(e: Base.Env, pos: Int, ids: Int) -> Result[Base.StmtAt]
  branches: List[Ast.IfBranch] = []
  cursor = pos
  next_id = ids
  looping = true
  while looping
    branch = try parse_if_branch(e, cursor, next_id)
    branches = branches.push(branch.node)
    cursor = branch.pos
    next_id = branch.ids
    looping = e.tokens[cursor].kind == "elsif"
  end

  else_body: Ast.Optional[List[Ast.Stmt]] = Ast.Optional.Absent
  if e.tokens[cursor].kind == "else"
    if e.tokens[cursor + 1].kind == "if"
      return error(
        Base.unexpected_help(
          e,
          cursor + 1,
          "expected a newline after else, found \"if\"",
          "write elsif instead of else if",
        ),
      )
    end

    head = try expect_head_end(e, cursor + 1, "a newline after else", "else")
    body = try parse_block(e, head, next_id, 0)
    else_body = Ast.Optional.Present(body.nodes)
    cursor = body.pos
    next_id = body.ids
  end

  close = try expect_end(e, cursor)
  stop = try expect_statement_end(e, close, "a newline after end")
  return stmt_at(
    Ast.Stmt.If(Ast.IfStmt(id: next_id, branches: branches, else_body: else_body, span: Base.span_from(e, pos, stop))),
    stop,
    next_id,
  )
end

def parse_while(e: Base.Env, pos: Int, ids: Int) -> Result[Base.StmtAt]
  condition = try parse_expression(Base.with_blocks(e, false), pos + 1, ids)
  cursor = condition.pos
  if e.tokens[cursor].kind == "do"
    cursor += 1
  end

  head = try expect_head_end(e, cursor, "a newline after the condition", "while cond")
  body = try parse_block(e, head, condition.ids, 0)
  close = try expect_end(e, body.pos)
  stop = try expect_statement_end(e, close, "a newline after end")
  return stmt_at(
    Ast.Stmt.While(
      Ast.WhileStmt(id: body.ids, condition: condition.node, body: body.nodes, span: Base.span_from(e, pos, stop)),
    ),
    stop,
    body.ids,
  )
end

def parse_for(e: Base.Env, pos: Int, ids: Int) -> Result[Base.StmtAt]
  after_name = try Base.expect(e, pos + 1, "name", "a loop variable", false)
  after_in = try Base.expect(e, after_name, "in", "\"in\"", false)
  iterable = try parse_expression(Base.with_blocks(e, false), after_in, ids)
  cursor = iterable.pos
  if e.tokens[cursor].kind == "do"
    cursor += 1
  end

  head = try expect_head_end(e, cursor, "a newline after the loop header", "for x in xs")
  body = try parse_block(e, head, iterable.ids, 0)
  close = try expect_end(e, body.pos)
  stop = try expect_statement_end(e, close, "a newline after end")
  return stmt_at(
    Ast.Stmt.For(
      Ast.ForStmt(
        id: body.ids,
        variable: e.tokens[pos + 1].lexeme,
        variable_span: e.tokens[pos + 1].span,
        iterable: iterable.node,
        body: body.nodes,
        span: Base.span_from(e, pos, stop),
      ),
    ),
    stop,
    body.ids,
  )
end

def unclosed_case(e: Base.Env, pos: Int) -> String
  return Base.bail(e, pos, "PARSE-UNCLOSED-BLOCK", "unclosed case block, expected end", Diag.Help.NoHelp)
end

# The body of an arm ends at the next arm or at end: arms have no closing token, so case_arm_start? looks ahead for a
# pattern and ->.
def parse_case_body(e: Base.Env, pos: Int, ids: Int) -> Result[Base.StmtsAt]
  inner = Base.with_depth(e, 0)
  nodes: List[Ast.Stmt] = []
  cursor = pos
  next_id = ids
  looping = true
  while looping
    cursor = Base.skip_newlines(e, cursor)
    if e.tokens[cursor].kind == "end" or Base.case_arm_start?(e, cursor)
      looping = false
    elsif e.tokens[cursor].kind == "EOF"
      return error(unclosed_case(e, cursor))
    else
      parsed = try parse_statement(inner, cursor, next_id)
      nodes = nodes.push(parsed.node)
      cursor = parsed.pos
      next_id = parsed.ids
    end
  end

  return ok(Base.StmtsAt(nodes: nodes, pos: cursor, ids: next_id))
end

def parse_arm_body(e: Base.Env, pos: Int, ids: Int) -> Result[Base.StmtsAt]
  if e.tokens[pos].kind == "NL"
    return parse_case_body(e, pos + 1, ids)
  end

  first = try parse_simple_statement(Base.with_depth(e, 0), pos, ids)
  rest = try parse_case_body(e, first.pos, first.ids)
  return ok(Base.StmtsAt(nodes: List.concat([first.node], rest.nodes), pos: rest.pos, ids: rest.ids))
end

# The optional `if condition` between a pattern and ->. Its ids come after the pattern and before the body.
def parse_guard(e: Base.Env, pos: Int, ids: Int) -> Result[GuardAt]
  if e.tokens[pos].kind != "if"
    return ok(GuardAt(node: Ast.Optional.Absent, pos: pos, ids: ids))
  end

  condition = try parse_expression(e, pos + 1, ids)
  return ok(GuardAt(node: Ast.Optional.Present(condition.node), pos: condition.pos, ids: condition.ids))
end

def parse_case(e: Base.Env, pos: Int, ids: Int) -> Result[Base.StmtAt]
  value = try parse_expression(Base.with_blocks(e, false), pos + 1, ids)
  cursor = value.pos
  if e.tokens[cursor].kind == "do"
    cursor += 1
  end

  cursor = try expect_head_end(e, cursor, "a newline after the case value", "case value")
  arms: List[Ast.CaseArm] = []
  next_id = value.ids
  looping = true
  while looping
    cursor = Base.skip_newlines(e, cursor)
    kind = e.tokens[cursor].kind
    if kind == "end"
      if arms.size == 0
        return error(Base.unexpected(e, cursor, "case requires at least one arm"))
      end

      looping = false
    elsif kind == "EOF"
      return error(unclosed_case(e, cursor))
    else
      arm_start = cursor
      pattern = try Base.parse_pattern(e, cursor, next_id)
      guard = try parse_guard(e, pattern.pos, pattern.ids)
      arrow = try Base.expect(e, guard.pos, "arrow", "->", false)
      body = try parse_arm_body(e, arrow, guard.ids)
      arms = arms.push(
        Ast.CaseArm(
          id: body.ids,
          pattern: pattern.node,
          guard: guard.node,
          body: body.nodes,
          span: Base.span_from(e, arm_start, body.pos),
        ),
      )
      cursor = body.pos
      next_id = body.ids + 1
    end
  end

  close = try expect_end(e, cursor)
  stop = try expect_statement_end(e, close, "a newline after end")
  return stmt_at(
    Ast.Stmt.Case(Ast.CaseStmt(id: next_id, value: value.node, arms: arms, span: Base.span_from(e, pos, stop))),
    stop,
    next_id,
  )
end

# The parameters of a def up to ")". extern is true in an extern block, where `out NAME: type` marks an out parameter
# and `...` the start of the variadic part; elsewhere those are PARSE-EXTERN-OUT at the word out and
# PARSE-EXTERN-VARIADIC at the `...`.
def parse_parameters(e: Base.Env, pos: Int, ids: Int, extern: Bool) -> Result[ParamsAt]
  nodes: List[Ast.Param] = []
  outs: List[Bool] = []
  fixed = -1
  mark = -1
  if e.tokens[pos].kind == "right-paren"
    return ok(ParamsAt(nodes: nodes, outs: outs, fixed: fixed, mark: mark, pos: pos, ids: ids))
  end

  cursor = pos
  next_id = ids
  looping = true
  while looping
    if e.tokens[cursor].kind == "dot-dot-dot"
      fixed = try variadic_marker(e, cursor, nodes.size, fixed, extern)
      mark = cursor
      cursor += 1
    else
      start = cursor
      out = out_start?(e, cursor)
      if out and !extern
        return error(
          Base.bail(
            e,
            cursor,
            "PARSE-EXTERN-OUT",
            "only a function of an extern block has out parameters",
            Base.hint("return the values in a struct"),
          ),
        )
      end

      if out
        cursor += 1
      end

      outs = outs.push(out)
      after_name = try Base.expect(e, cursor, "name", "a parameter name", false)
      colon = try Base.expect(e, after_name, "colon", "\":\"", false)
      type = try Base.parse_type(e, colon, next_id)
      default: Ast.Optional[Ast.Expr] = Ast.Optional.Absent
      after_type = type.pos
      param_id = type.ids
      # Any expression is read after "=", so that the checker can say why a default is not a constant. The id of the
      # parameter follows the ids of its default (post-order).
      if e.tokens[after_type].kind == "assign"
        value = try parse_expression(e, after_type + 1, type.ids)
        default = Ast.Optional.Present(value.node)
        after_type = value.pos
        param_id = value.ids
      end

      nodes = nodes.push(
        Ast.Param(
          id: param_id,
          name: e.tokens[cursor].lexeme,
          name_span: e.tokens[cursor].span,
          type: type.node,
          default: default,
          span: Base.span_from(e, start, after_type),
        ),
      )
      cursor = after_type
      next_id = param_id + 1
    end

    if e.tokens[cursor].kind == "comma"
      cursor += 1
      if e.tokens[cursor].kind == "right-paren"
        looping = false
      end
    else
      looping = false
    end
  end

  return ok(ParamsAt(nodes: nodes, outs: outs, fixed: fixed, mark: mark, pos: cursor, ids: next_id))
end

# The `...` at `at`, after `count` parameters, gives the number of fixed parameters: PARSE-EXTERN-VARIADIC outside an
# extern block or for a second `...` (fixed is not -1), and PARSE-EXTERN-VARIADIC-FIXED before any parameter, as C
# needs one to find the others.
def variadic_marker(e: Base.Env, at: Int, count: Int, fixed: Int, extern: Bool) -> Result[Int]
  if !extern
    return error(
      Base.bail(
        e,
        at,
        "PARSE-EXTERN-VARIADIC",
        "only a function of an extern block has a variadic part",
        Base.hint("take the values as a List"),
      ),
    )
  end

  if fixed >= 0
    return error(
      Base.bail(
        e,
        at,
        "PARSE-EXTERN-VARIADIC",
        "an extern function has one ... at most",
        Base.hint("declare the variadic arguments after one ..., or declare the function again in another shape"),
      ),
    )
  end

  if count == 0
    return error(
      Base.bail(
        e,
        at,
        "PARSE-EXTERN-VARIADIC-FIXED",
        "a variadic function takes at least one parameter before ...",
        Base.hint("declare the fixed parameters of the C function first, as its header does"),
      ),
    )
  end

  return ok(count)
end

# `out` is a plain name: before a parameter name it marks an out parameter.
def out_start?(e: Base.Env, at: Int) -> Bool
  return e.tokens[at].kind == "name" and e.tokens[at].lexeme == "out" and Base.kind_at(e, at + 1) == "name"
end

def decl_at(node: Ast.Decl, pos: Int, ids: Int) -> Result[DeclAt]
  return ok(DeclAt(node: node, pos: pos, ids: ids + 1))
end

def parse_function_decl(e: Base.Env, pos: Int, ids: Int, doc: Ast.Optional[String]) -> Result[DeclAt]
  after_name = try Base.expect(e, pos + 1, "name", "a function name", true)
  after_open = try Base.expect(e, after_name, "left-paren", "\"(\"", false)
  params = try parse_parameters(e, after_open, ids, false)
  after_params = try Base.expect(e, params.pos, "right-paren", "\")\"", false)
  if e.tokens[after_params].kind == "left-brace"
    return error(
      Base.unexpected_help(
        e,
        after_params,
        "expected \"->\", found #{Base.describe(e.tokens[after_params])}",
        brace_help("def name() -> Type"),
      ),
    )
  end

  after_arrow = try Base.expect(e, after_params, "arrow", "\"->\"", false)
  result = try Base.parse_type(e, after_arrow, params.ids)
  head = try expect_head_end(e, result.pos, "a newline after the function signature", "def name() -> Type")
  body = try parse_block(e, head, result.ids, 0)
  close = try expect_end(e, body.pos)
  stop = try expect_statement_end(e, close, "a newline after end")
  node = Ast.Decl.Function(
    Ast.FunctionDecl(
      id: body.ids,
      name: e.tokens[pos + 1].lexeme,
      name_span: e.tokens[pos + 1].span,
      params: params.nodes,
      result: result.node,
      body: body.nodes,
      doc: doc,
      native: Ast.Optional.Absent,
      span: Base.span_from(e, pos, stop),
    ),
  )
  return decl_at(node, stop, body.ids)
end

# extern "library" NL, then [##doc] [export] members, then end. A member is [compute] def, a function with no body
# (Ast.Native), so the later stages see ordinary functions, resource Name, free: c_name, or struct Name ... end, a C
# struct passed by value. A resource or a struct names a type that the members below it may use; no def of the block
# may be the free function of a resource, which the VM alone calls.
def parse_extern_block(e: Base.Env, pos: Int, ids: Int) -> Result[DeclsAt]
  library = pos + 1
  if Base.kind_at(e, library) == "string" and Base.heredoc?(e.tokens[library])
    return error(
      Base.unexpected_help(
        e,
        library,
        "a library name is not a heredoc",
        "write the library as a \"...\" string literal",
      ),
    )
  end

  if Base.kind_at(e, library) == "interp-start"
    return error(
      Base.bail_span(
        "PARSE-EXTERN-LIBRARY",
        "a library name is not an interpolated string",
        Base.span_from(e, library, interpolation_end(e, library) + 1),
        Base.hint(EXTERN_LIBRARY_HELP),
      ),
    )
  end

  after_library = try Base.expect(e, library, "string", "a library name", false)
  name = Base.token_text(e.tokens[library])
  if !library_name?(name)
    return error(
      Base.bail(
        e,
        library,
        "PARSE-EXTERN-LIBRARY",
        "\"#{name}\" is not a library name or an absolute path",
        Base.hint(EXTERN_LIBRARY_HELP),
      ),
    )
  end

  cursor = try Base.expect(e, after_library, "NL", "a newline after the library name", false)
  block = ExternBlock(
    library: name, resources: {}, structs: {}, symbols: Set.new([]), with_types: declares_types?(e, cursor),
  )
  nodes: List[Ast.Decl] = []
  next_id = ids
  looping = true
  while looping
    cursor = Base.skip_newlines(e, cursor)
    if e.tokens[cursor].kind == "end"
      looping = false
    else
      taken = try documented(e, cursor, "extern")
      at = taken.pos
      exported = e.tokens[at].kind == "export"
      if exported
        at += 1
      end

      taken_member = try parse_extern_member(e, at, next_id, taken.doc, block)
      member = taken_member.decl
      block = taken_member.block
      node = member.node
      member_ids = member.ids
      span = Base.span_from(e, taken.pos, member.pos)
      if exported
        node = Ast.Decl.Export(Ast.ExportDecl(id: member_ids, declaration: member.node, doc: taken.doc, span: span))
        member_ids += 1
      end

      nodes = nodes.push(node)
      # The record comes after its function, so a lookup by the name's position finds the function first.
      for record in taken_member.records
        if exported
          wrapped = Ast.ExportDecl(id: member_ids, declaration: record, doc: record_doc(record), span: span)
          nodes = nodes.push(Ast.Decl.Export(wrapped))
          member_ids += 1
        else
          nodes = nodes.push(record)
        end
      end

      cursor = member.pos
      next_id = member_ids
    end
  end

  stop = try expect_statement_end(e, cursor + 1, "a newline after end")
  return ok(DeclsAt(nodes: nodes, pos: stop, ids: next_id))
end

# Whether a member of the extern block that starts at pos is a resource or a struct. Only a struct has an `end` of its
# own, so the first `end` closes the block or comes after a struct.
def declares_types?(e: Base.Env, pos: Int) -> Bool
  at = pos
  while at < e.size and e.tokens[at].kind != "end"
    if resource_start?(e, at) or e.tokens[at].kind == "struct"
      return true
    end

    at += 1
  end

  return false
end

# One member of an extern block at pos (after its doc and export), and the block with it.
def parse_extern_member(
  e: Base.Env,
  pos: Int,
  ids: Int,
  doc: Ast.Optional[String],
  block: ExternBlock,
) -> Result[MemberAt]
  if resource_start?(e, pos)
    member = try parse_resource(e, pos, ids, doc, block)
    free = e.tokens[pos + 5].lexeme
    if e.tokens[pos + 5].kind == "type-name" and e.tokens[pos + 6].kind == "dot"
      free = FUNCTION_TYPE
    end

    named = block.resources.put(e.tokens[pos + 1].lexeme, free)
    return ok(MemberAt(decl: member, block: block.with(resources: named), records: []))
  end

  if e.tokens[pos].kind == "struct"
    made = try parse_extern_struct(e, pos, ids, doc, block)
    laid_out = block.structs.put(e.tokens[pos + 1].lexeme, made.layout)
    return ok(MemberAt(decl: made.decl, block: block.with(structs: laid_out), records: []))
  end

  at = pos
  if compute_start?(e, at)
    at += 1
  end

  if e.tokens[at].kind != "def"
    return error(Base.found(e, at, "def, compute def, resource, struct or end in an extern block"))
  end

  member = try parse_extern_function(e, pos, at, ids, doc, block)
  symbols = block.symbols
  if member.symbol != ""
    symbols = symbols.add(member.symbol)
  end

  return ok(MemberAt(decl: member.decl, block: block.with(symbols: symbols), records: member.records))
end

# `resource` is a plain name: inside an extern block, before a type name, it declares a resource.
def resource_start?(e: Base.Env, at: Int) -> Bool
  return e.tokens[at].kind == "name" and e.tokens[at].lexeme == "resource" and Base.kind_at(e, at + 1) == "type-name"
end

# resource Name, free: c_name NL in an extern block, or free: C.Function, when each value has its own free function,
# which the call that makes it takes. pos is the word resource. The C name may start with a capital letter
# (PQfinish, SSL_free): only a dotted type after the colon (C.Function) is read as a type, so a bare name is always a C
# name, whatever types the program declares.
def parse_resource(e: Base.Env, pos: Int, ids: Int, doc: Ast.Optional[String], block: ExternBlock) -> Result[DeclAt]
  after_name = try Base.expect(e, pos + 1, "type-name", "a resource name", false)
  after_comma = try Base.expect(e, after_name, "comma", "\",\"", false)
  after_word = try expect_word(e, after_comma, "free", "write resource Name, free: c_function")
  after_colon = try Base.expect(e, after_word, "colon", "\":\"", false)
  if Base.kind_at(e, after_colon) == "type-name" and Base.kind_at(e, after_colon + 1) == "dot"
    return parse_resource_by_pointer(e, pos, ids, doc, after_colon)
  end

  after_free = try expect_c_name(e, after_colon, "the C name of the free function or C.Function")
  free = e.tokens[after_colon].lexeme
  if free.ends_with?("?") or free.ends_with?("!")
    return error(c_name_failure(e, after_colon, free))
  end

  if block.symbols.include?(free)
    return error(free_failure(e, after_colon, free))
  end

  stop = try expect_statement_end(e, after_free, "a newline after the resource")
  node = Ast.Decl.Resource(
    Ast.ResourceDecl(
      id: ids,
      name: e.tokens[pos + 1].lexeme,
      name_span: e.tokens[pos + 1].span,
      free: free,
      doc: doc,
      span: Base.span_from(e, pos, stop),
    ),
  )
  return decl_at(node, stop, ids)
end

# The position after a C name at pos: a name (with a ? or ! left for the caller to reject) or a type-name, which is
# only a name that starts with a capital letter.
def expect_c_name(e: Base.Env, pos: Int, description: String) -> Result[Int]
  if Base.kind_at(e, pos) == "type-name"
    return ok(pos + 1)
  end

  return Base.expect(e, pos, "name", description, true)
end

# The rest of resource Name, free: C.Function from at, the dotted type after the colon: any type but C.Function is
# PARSE-EXTERN-FUNCTION at it.
def parse_resource_by_pointer(e: Base.Env, pos: Int, ids: Int, doc: Ast.Optional[String], at: Int) -> Result[DeclAt]
  type = try Base.parse_type(e, at, ids)
  if type.node.name != FUNCTION_TYPE or type.node.args.size > 0
    return error(
      Base.bail_span(
        "PARSE-EXTERN-FUNCTION",
        "the free function of a resource is a C name or C.Function, not #{type.node.name}",
        type.node.span,
        Base.hint("write free: c_function, or free: C.Function when the call that makes the resource takes it"),
      ),
    )
  end

  stop = try expect_statement_end(e, type.pos, "a newline after the resource")
  node = Ast.Decl.Resource(
    Ast.ResourceDecl(
      id: ids,
      name: e.tokens[pos + 1].lexeme,
      name_span: e.tokens[pos + 1].span,
      free: FUNCTION_TYPE,
      doc: doc,
      span: Base.span_from(e, pos, stop),
    ),
  )
  return decl_at(node, stop, ids)
end

# struct Name NL fields end NL in an extern block at pos: a C struct that extern functions take and return by value,
# an ordinary struct (a record) for the rest of the language. Each field has a C type of STRUCT_FIELD_CODES, or is a
# struct declared above in the block, and the program sees its Agentica type. The layout code lists the codes of the
# fields in their order, which is the order of the record and of the C struct.
def parse_extern_struct(
  e: Base.Env,
  pos: Int,
  ids: Int,
  doc: Ast.Optional[String],
  block: ExternBlock,
) -> Result[ExternStructAt]
  parsed = try parse_struct(e, pos, ids, doc)
  node = parsed.node
  codes: List[String] = []
  fields: List[Ast.FieldDecl] = []
  for field in node.fields
    code = struct_field_code(field.type, block)
    if code == ""
      help = STRUCT_FIELD_HELP
      if field.type.args.size == 0
        help = TYPE_NAME_HELP.get(field.type.name, help)
      end

      return error(
        Base.bail_span(
          "PARSE-EXTERN-TYPE",
          "#{field.type.name} is not a field type of a C struct",
          field.type.span,
          Base.hint(help),
        ),
      )
    end

    codes = codes.push(code)
    if code.size == 1
      fields = fields.push(field.with(type: field.type.with(name: EXTERN_TYPES[code])))
    else
      fields = fields.push(field)
    end
  end

  layout = "{#{codes.join("")}}"
  try struct_size(node, layout)
  decl = try decl_at(Ast.Decl.Struct(node.with(fields: fields)), parsed.pos, parsed.ids)
  return ok(ExternStructAt(decl: decl, layout: layout))
end

# The code of a field of a C struct: of its C type, or the layout code of a struct of the block; "" for any other type.
def struct_field_code(type: Ast.TypeRef, block: ExternBlock) -> String
  if type.args.size > 0
    return ""
  end

  return STRUCT_FIELD_CODES.get(type.name, block.structs.get(type.name, ""))
end

# PARSE-EXTERN-TYPE at the name of a C struct without fields (C has none), and PARSE-EXTERN-ARITY at the name of one
# with more fields than the VM takes, nested ones counted, or nested deeper.
def struct_size(node: Ast.StructDecl, layout: String) -> Result[Void]
  if node.fields.size == 0
    return error(
      Base.bail_span(
        "PARSE-EXTERN-TYPE",
        "the C struct #{node.name} has no fields",
        node.name_span,
        Base.hint("declare the fields of the C struct, in the order of its header"),
      ),
    )
  end

  depth = 0
  deepest = 0
  leaves = 0
  for char in layout.split("")
    if char == "{"
      depth += 1
      if depth > deepest
        deepest = depth
      end
    elsif char == "}"
      depth -= 1
    else
      leaves += 1
    end
  end

  if leaves > STRUCT_MAX_FIELDS or deepest > STRUCT_MAX_DEPTH
    return error(
      Base.bail_span(
        "PARSE-EXTERN-ARITY",
        "a C struct has at most #{STRUCT_MAX_FIELDS} fields and #{STRUCT_MAX_DEPTH} levels, nested structs counted",
        node.name_span,
        Base.hint("split the struct, or keep a part of it as a C.Pointer to memory read with Native.get_*"),
      ),
    )
  end

  return ok()
end

def c_name_failure(e: Base.Env, at: Int, name: String) -> String
  return Base.bail(
    e,
    at,
    "PARSE-EXTERN-NAME",
    "\"#{name}\" is not a C function name",
    Base.hint("an extern function is named as in C: letters, digits and _, without ? or !"),
  )
end

# PARSE-EXTERN-FREE at the name: a def of the free function would let the program free the pointer that the VM frees
# again on close or at the end of the owning task.
def free_failure(e: Base.Env, at: Int, name: String) -> String
  return Base.bail(
    e,
    at,
    "PARSE-EXTERN-FREE",
    "\"#{name}\" is the free function of a resource of this block, so it cannot also be declared with def",
    Base.hint("close the resource with Native.close(resource), which calls #{name} once"),
  )
end

# [compute] def name(params) -> Type [= "symbol"] NL in an extern block: a C name, C types, no defaults, and `...`
# before the variadic part of a variadic C function. The C name is the def's unless the string gives it. start is the
# first token (compute or def) and pos the def. A function with out parameters takes only the others, and returns its
# record, made here (Ast.StructDecl.record_of): the C result as `result` (none for Void), then each out value, named
# after it. A first parameter of type C.Function makes it a call through a function pointer: the def calls that
# address, has no C name (ExternAt.symbol is ""), and takes no = "symbol". A sole C.Function parameter of a def that
# returns a resource of a free: C.Function kind is that resource's free function instead (callee?).
def parse_extern_function(
  e: Base.Env,
  start: Int,
  pos: Int,
  ids: Int,
  doc: Ast.Optional[String],
  block: ExternBlock,
) -> Result[ExternAt]
  after_name = try Base.expect(e, pos + 1, "name", "a function name", true)
  name = e.tokens[pos + 1].lexeme
  if name.ends_with?("?") or name.ends_with?("!")
    return error(c_name_failure(e, pos + 1, name))
  end

  after_open = try Base.expect(e, after_name, "left-paren", "\"(\"", false)
  params = try parse_parameters(e, after_open, ids, true)
  after_params = try Base.expect(e, params.pos, "right-paren", "\")\"", false)
  after_arrow = try Base.expect(e, after_params, "arrow", "\"->\"", false)
  result = try Base.parse_type(e, after_arrow, params.ids)
  symbol_at = pos + 1
  after_signature = result.pos
  if e.tokens[after_signature].kind == "assign"
    symbol_at = after_signature + 1
    after_signature = try symbol_string(e, symbol_at)
  end

  symbol = Base.token_text(e.tokens[symbol_at])
  callee = callee?(params, result.node, block)
  if callee and symbol_at != pos + 1
    return error(
      Base.bail_span(
        "PARSE-EXTERN-FUNCTION",
        "a call through a C.Function has no C name",
        Base.span_from(e, symbol_at, after_signature),
        Base.hint("the def calls the address of its first parameter: write it without = \"symbol\""),
      ),
    )
  end

  if !callee and block.resources.values.any? do |free: String| free == symbol end
    return error(free_failure(e, symbol_at, symbol))
  end

  stop = try expect_statement_end(e, after_signature, "a newline after the extern function")
  next_id = result.ids
  codes: List[String] = []
  returned = try extern_type(result.node, true, block, next_id)
  next_id = returned.ids
  codes = codes.push(returned.code)
  if params.nodes.size > EXTERN_MAX_PARAMS
    return error(
      Base.bail_span(
        "PARSE-EXTERN-ARITY",
        "an extern function takes at most #{EXTERN_MAX_PARAMS} parameters",
        params.nodes[EXTERN_MAX_PARAMS].span,
        Base.hint("pass the values in fewer parameters"),
      ),
    )
  end

  typed: List[Ast.Param] = []
  fields: List[Ast.FieldDecl] = []
  outs: List[Ast.NativeResource] = []
  # The types of the resources of a free: C.Function kind that the call makes, and the free C.Function parameter.
  by_pointer: List[Ast.TypeRef] = []
  if returned.code == "r" and block.resources[result.node.name] == FUNCTION_TYPE
    by_pointer = by_pointer.push(result.node)
  end

  free_params: List[Ast.Param] = []
  # The C.Function parameters before the ... of a variadic def, which C does not get.
  not_c = 0
  index = 0
  for param in params.nodes
    case param.default
      Ast.Optional.Present(value) ->
        return error(
          Base.bail_span(
            "PARSE-EXTERN-DEFAULT",
            "the extern parameter \"#{param.name}\" has a default value",
            param.span,
            Base.hint("C has no default values: write the parameter without = value"),
          ),
        )
      Ast.Optional.Absent -> codes = codes
    end

    taken = try extern_type(param.type, false, block, next_id)
    next_id = taken.ids
    if index == params.fixed
      codes = codes.push(VARIADIC_MARK)
    end

    if params.fixed >= 0 and index >= params.fixed
      try variadic_type(param, taken, params.outs[index])
    end

    # An in and an out parameter of one name would be a parameter of the function and a field of its record; two of
    # the same side are the checker's CHECK-REDEFINED-NAME.
    if other_side?(params, index)
      return error(
        Base.bail_span(
          "PARSE-EXTERN-OUT",
          "the parameter \"#{param.name}\" is declared twice",
          param.name_span,
          Base.hint("give one of them another name"),
        ),
      )
    end

    if params.outs[index]
      field = try out_field(param, taken, returned.code)
      codes = codes.push(taken.code.upcase)
      fields = fields.push(field)
      if taken.code == "r"
        outs = outs.push(Ast.NativeResource(name: param.type.name, free: block.resources[param.type.name]))
        if block.resources[param.type.name] == FUNCTION_TYPE
          by_pointer = by_pointer.push(param.type)
        end
      end
    else
      code = taken.code
      if code == "c" and (index > 0 or !callee)
        if index != params.nodes.size - 1
          return error(function_failure(param.type))
        end

        code = "e"
        free_params = free_params.push(param)
      end

      if (code == "c" or code == "e") and index < params.fixed
        not_c += 1
      end

      codes = codes.push(code)
      typed = typed.push(param.with(type: taken.type))
    end

    index += 1
  end

  try free_function(by_pointer, free_params)
  if params.fixed > 0 and params.fixed == not_c
    return error(
      Base.bail(
        e,
        params.mark,
        "PARSE-EXTERN-VARIADIC-FIXED",
        "a variadic function takes at least one parameter before ..., besides its C.Function ones",
        Base.hint("declare the fixed parameters of the C function first, as its header does"),
      ),
    )
  end

  # An empty variadic part (`def printf(format: C.String, ...)`) still marks the call as variadic.
  if params.fixed == params.nodes.size
    codes = codes.push(VARIADIC_MARK)
  end

  resource = ""
  free = ""
  if returned.code == "r"
    resource = result.node.name
    free = block.resources[resource]
  end

  span = Base.span_from(e, start, stop)
  records: List[Ast.Decl] = []
  result_type = returned.type
  if fields.size > 0
    record = record_name(name)
    if record == ""
      return error(
        Base.bail(
          e,
          pos + 1,
          "PARSE-EXTERN-OUT",
          "\"#{name}\" gives no name for the record of its out parameters",
          Base.hint("the record is named after the function in CamelCase, so the name needs a letter after its _"),
        ),
      )
    end

    if returned.code != "v"
      first = Ast.FieldDecl(
        id: next_id,
        name: "result",
        name_span: result.node.span,
        type: returned.type,
        default: Ast.Optional.Absent,
        doc: Ast.Optional.Absent,
        span: result.node.span,
      )
      fields = [first].concat(fields)
      next_id += 1
    end

    made = Ast.StructDecl(
      id: next_id,
      name: record,
      name_span: e.tokens[pos + 1].span,
      fields: fields,
      doc: Ast.Optional.Present("The result of `#{name}`."),
      record_of: name,
      span: span,
    )
    records = records.push(Ast.Decl.Struct(made))
    result_type = Ast.TypeRef(id: next_id + 1, name: record, args: [], span: result.node.span)
    next_id += 2
  end

  node = Ast.Decl.Function(
    Ast.FunctionDecl(
      id: next_id,
      name: name,
      name_span: e.tokens[pos + 1].span,
      params: typed,
      result: result_type,
      body: [],
      doc: doc,
      native: Ast.Optional.Present(
        Ast.Native(
          library: block.library,
          symbol: symbol,
          codes: codes.join(""),
          compute: start != pos,
          resource: resource,
          free: free,
          outs: outs,
          with_types: block.with_types,
        ),
      ),
      span: span,
    ),
  )
  decl = try decl_at(node, stop, next_id)
  if callee
    symbol = ""
  end

  return ok(ExternAt(decl: decl, symbol: symbol, records: records))
end

# PARSE-EXTERN-FUNCTION at the type of a C.Function parameter that is neither the function to call nor a free function.
def function_failure(type: Ast.TypeRef) -> String
  return Base.bail_span(
    "PARSE-EXTERN-FUNCTION",
    "a C.Function parameter is the function to call or a free function",
    type.span,
    Base.hint(FUNCTION_HELP),
  )
end

# Whether the first parameter is a C.Function (not an out one): the def calls the function at that address. A sole
# C.Function parameter of a def that returns a resource of a free: C.Function kind is its free function, so
# `def thing_new(free: C.Function) -> Thing` calls thing_new by name; a call through a pointer that makes such a
# resource takes two. (A def with out parameters has its free function last, so its first parameter is not it.)
def callee?(params: ParamsAt, result: Ast.TypeRef, block: ExternBlock) -> Bool
  if params.nodes.size == 0 or params.outs[0]
    return false
  end

  first = params.nodes[0].type
  if first.name != FUNCTION_TYPE or first.args.size > 0
    return false
  end

  return params.nodes.size > 1 or block.resources.get(result.name, "") != FUNCTION_TYPE
end

# A call that makes a resource of a free: C.Function kind (made: the type of each) takes its free function as its last
# parameter, a C.Function (free_params: none or that one), and a call that makes none takes no such parameter; one call
# makes one such resource at most. Else PARSE-EXTERN-FUNCTION.
def free_function(made: List[Ast.TypeRef], free_params: List[Ast.Param]) -> Result[Void]
  if made.size > 1
    return error(
      Base.bail_span(
        "PARSE-EXTERN-FUNCTION",
        "a call makes one resource of a free: C.Function kind at most",
        made[1].span,
        Base.hint("declare the resources with their own free functions, or split the call"),
      ),
    )
  end

  if made.size == 1 and free_params.size == 0
    return error(
      Base.bail_span(
        "PARSE-EXTERN-FUNCTION",
        "#{made[0].name} is freed through a C.Function that the call takes",
        made[0].span,
        Base.hint("add the free function as the last parameter: free: C.Function"),
      ),
    )
  end

  if made.size == 0 and free_params.size == 1
    return error(function_failure(free_params[0].type))
  end

  return ok()
end

# The string at `at` after the = of an extern function, which names its C function, and the position after it: a
# plain "..." literal holding a C name, else PARSE-EXTERN-SYMBOL at it.
def symbol_string(e: Base.Env, at: Int) -> Result[Int]
  kind = Base.kind_at(e, at)
  stop = at + 1
  if kind == "interp-start"
    stop = interpolation_end(e, at) + 1
  end

  if kind == "string" and !Base.heredoc?(e.tokens[at]) and c_name?(Base.token_text(e.tokens[at]))
    return ok(stop)
  end

  if kind != "string" and kind != "interp-start"
    return error(Base.found(e, at, "the C name of the function as a string"))
  end

  return error(
    Base.bail_span(
      "PARSE-EXTERN-SYMBOL",
      "the C name of an extern function is a plain string of letters, digits and _",
      Base.span_from(e, at, stop),
      Base.hint(EXTERN_SYMBOL_HELP),
    ),
  )
end

# A C identifier: letters, digits and _, not starting with a digit. The VM reads the name up to a space.
def c_name?(text: String) -> Bool
  if text == "" or DIGITS.include?(text.slice(0, 1))
    return false
  end

  return text.split("").all? do |char: String| C_NAME_CHARS.include?(char) end
end

# PARSE-EXTERN-VARIADIC-TYPE for a parameter of the variadic part that C would promote (C.Bool, C.Float and the four
# integer types narrower than an int) or that is an out parameter.
def variadic_type(param: Ast.Param, taken: ExternType, out: Bool) -> Result[Void]
  if out
    return error(
      Base.bail_span(
        "PARSE-EXTERN-VARIADIC-TYPE",
        "the variadic parameter \"#{param.name}\" cannot be an out parameter",
        param.span,
        Base.hint(VARIADIC_HELP),
      ),
    )
  end

  if !VARIADIC_CODES.include?(taken.code)
    return error(
      Base.bail_span(
        "PARSE-EXTERN-VARIADIC-TYPE",
        "#{param.type.name} cannot be a variadic parameter",
        param.type.span,
        Base.hint(VARIADIC_HELP),
      ),
    )
  end

  return ok()
end

# The field of the record for an out parameter, of the parameter's Agentica type (a resource itself, not a Result), or
# PARSE-EXTERN-OUT: at the type for C.String and C.Bytes (who frees what C writes there is not known) and C.Function
# (an out function pointer is a C.Pointer), and at the name for `result`, which the C result takes unless it is Void.
def out_field(param: Ast.Param, taken: ExternType, result: String) -> Result[Ast.FieldDecl]
  if taken.code.starts_with?("{")
    return error(
      Base.bail_span(
        "PARSE-EXTERN-OUT",
        "the struct #{param.type.name} cannot be an out parameter",
        param.type.span,
        Base.hint(STRUCT_OUT_HELP),
      ),
    )
  end

  if taken.code == "s" or taken.code == "y" or taken.code == "c"
    return error(
      Base.bail_span(
        "PARSE-EXTERN-OUT",
        "#{param.type.name} cannot be an out parameter",
        param.type.span,
        Base.hint(EXTERN_OUT_HELP),
      ),
    )
  end

  if param.name == "result" and result != "v"
    return error(
      Base.bail_span(
        "PARSE-EXTERN-OUT",
        "an out parameter cannot be named result, which holds the C result",
        param.name_span,
        Base.hint("give the out parameter another name"),
      ),
    )
  end

  field = Ast.FieldDecl(
    id: param.id,
    name: param.name,
    name_span: param.name_span,
    type: taken.type,
    default: Ast.Optional.Absent,
    doc: Ast.Optional.Absent,
    span: param.span,
  )
  return ok(field)
end

# Whether a parameter before the one at index has its name and is on the other side (in or out).
def other_side?(params: ParamsAt, index: Int) -> Bool
  at = 0
  while at < index
    if params.nodes[at].name == params.nodes[index].name and params.outs[at] != params.outs[index]
      return true
    end

    at += 1
  end

  return false
end

# The doc of a record, which its export repeats.
def record_doc(record: Ast.Decl) -> Ast.Optional[String]
  case record
    Ast.Decl.Struct(node) -> return node.doc
    _ -> return Ast.Optional.Absent
  end
end

# The name of the record of an extern function with out parameters: its name in CamelCase (sqlite3_open is
# Sqlite3Open), or "" when that does not start with a letter.
def record_name(name: String) -> String
  pieces = name.split("_").filter do |piece: String| piece != "" end
  words = pieces.map do |piece: String| piece.slice(0, 1).upcase + piece.slice(1, piece.size - 1) end
  joined = words.join("")
  if joined == "" or !"ABCDEFGHIJKLMNOPQRSTUVWXYZ".contains?(joined.slice(0, 1))
    return ""
  end

  return joined
end

# The code and the Agentica type of a C type of an extern signature, or PARSE-EXTERN-TYPE at it. Void is a result only,
# and C.Bytes (a List[Int] of bytes) a parameter only. A resource of the block is the resource as a parameter, and a
# Result of it as a result (NULL is an error). ids is the first free node id, for the types this adds.
def extern_type(ref: Ast.TypeRef, result: Bool, block: ExternBlock, ids: Int) -> Result[ExternType]
  code = ""
  if ref.args.size == 0
    found = EXTERN_CODES.get(ref.name)
    if found.ok? and !(result and (found.unwrap! == "y" or found.unwrap! == "c"))
      code = found.unwrap!
    elsif result and ref.name == "Void"
      code = "v"
    elsif block.resources.has_key?(ref.name)
      code = "r"
    elsif block.structs.has_key?(ref.name)
      code = block.structs[ref.name]
    end
  end

  if code == ""
    help = EXTERN_TYPES_HELP
    if TYPE_NAME_HELP.has_key?(ref.name) and ref.args.size == 0
      help = TYPE_NAME_HELP[ref.name]
    elsif ref.name == FUNCTION_TYPE and ref.args.size == 0
      help = FUNCTION_RESULT_HELP
    end

    return error(
      Base.bail_span(
        "PARSE-EXTERN-TYPE",
        "#{ref.name} is not a C type of an extern function",
        ref.span,
        Base.hint(help),
      ),
    )
  end

  if code.starts_with?("{")
    return ok(ExternType(code: code, type: ref, ids: ids))
  elsif code == "r" and result
    wrapped = Ast.TypeRef(id: ids, name: "Result", args: [ref], span: ref.span)
    return ok(ExternType(code: code, type: wrapped, ids: ids + 1))
  elsif code == "r"
    return ok(ExternType(code: code, type: ref, ids: ids))
  elsif code == "y"
    item = Ast.TypeRef(id: ids, name: "Int", args: [], span: ref.span)
    list = Ast.TypeRef(id: ids + 1, name: "List", args: [item], span: ref.span)
    return ok(ExternType(code: code, type: list, ids: ids + 2))
  end

  return ok(ExternType(code: code, type: ref.with(name: EXTERN_TYPES[code]), ids: ids))
end

def parse_field_decl(e: Base.Env, pos: Int, ids: Int, doc: Ast.Optional[String]) -> Result[FieldAt]
  after_name = try Base.expect(e, pos, "name", "a field name", false)
  colon = try Base.expect(e, after_name, "colon", "\":\"", false)
  type = try Base.parse_type(e, colon, ids)
  default: Ast.Optional[Ast.Expr] = Ast.Optional.Absent
  after_type = type.pos
  field_id = type.ids
  # As for a parameter, any expression is read after "=" so that the checker can say why a default is not a constant.
  # The id of the field follows the ids of its default (post-order).
  if e.tokens[after_type].kind == "assign"
    value = try parse_expression(e, after_type + 1, type.ids)
    default = Ast.Optional.Present(value.node)
    after_type = value.pos
    field_id = value.ids
  end

  stop = try Base.expect(e, after_type, "NL", "a newline after the field", false)
  node = Ast.FieldDecl(
    id: field_id,
    name: e.tokens[pos].lexeme,
    name_span: e.tokens[pos].span,
    type: type.node,
    default: default,
    doc: doc,
    span: Base.span_from(e, pos, stop),
  )
  return ok(FieldAt(node: node, pos: stop, ids: field_id + 1))
end

def parse_variant_decl(e: Base.Env, pos: Int, ids: Int, doc: Ast.Optional[String]) -> Result[VariantAt]
  cursor = try Base.expect(e, pos, "type-name", "an enum variant", false)
  payload: List[Ast.TypeRef] = []
  next_id = ids
  if e.tokens[cursor].kind == "left-paren"
    first = try Base.parse_type(e, cursor + 1, next_id)
    payload = payload.push(first.node)
    cursor = first.pos
    next_id = first.ids
    while e.tokens[cursor].kind == "comma"
      more = try Base.parse_type(e, cursor + 1, next_id)
      payload = payload.push(more.node)
      cursor = more.pos
      next_id = more.ids
    end

    cursor = try Base.expect(e, cursor, "right-paren", ")", false)
  end

  stop = try Base.expect(e, cursor, "NL", "a newline after the enum variant", false)
  node = Ast.EnumVariant(
    id: next_id,
    name: e.tokens[pos].lexeme,
    name_span: e.tokens[pos].span,
    payload_types: payload,
    doc: doc,
    span: Base.span_from(e, pos, stop),
  )
  return ok(VariantAt(node: node, pos: stop, ids: next_id + 1))
end

def starts_member?(e: Base.Env, pos: Int, member: String) -> Bool
  kind = e.tokens[pos].kind
  if member == "field"
    return kind == "name"
  end

  if member == "variant"
    return kind == "type-name"
  end

  if member == "extern"
    return kind == "def" or kind == "export" or compute_start?(e, pos) or resource_start?(e, pos)
  end

  return (
    kind == "def" or kind == "struct" or kind == "enum" or (kind == "export" and !reexport_start?(e, pos)) or
    constant_start?(e, pos) or (kind == "name" and e.tokens[pos].lexeme == "type")
  )
end

def doc_block(token: Tokens.Token) -> Tokens.DocBlock
  case token.value
    Tokens.Value.Doc(block) -> return block
    _ -> return Tokens.DocBlock(text: "", next: "")
  end
end

# A doc block has to be directly followed by a declaration, field or variant of the right kind (starts_member?), else
# PARSE-DETACHED-DOC at the doc.
def take_doc(e: Base.Env, pos: Int, member: String) -> Result[DocAt]
  block = doc_block(e.tokens[pos])
  if block.next == "code" and e.tokens[pos + 1].kind == "NL" and starts_member?(e, pos + 2, member)
    return ok(DocAt(doc: Ast.Optional.Present(block.text), pos: pos + 2))
  end

  return error(Base.bail_detached(e, pos))
end

def documented(e: Base.Env, pos: Int, member: String) -> Result[DocAt]
  if e.tokens[pos].kind == "DOC"
    return take_doc(e, pos, member)
  end

  return ok(DocAt(doc: Ast.Optional.Absent, pos: pos))
end

def parse_struct_decl(e: Base.Env, pos: Int, ids: Int, doc: Ast.Optional[String]) -> Result[DeclAt]
  parsed = try parse_struct(e, pos, ids, doc)
  return decl_at(Ast.Decl.Struct(parsed.node), parsed.pos, parsed.ids)
end

# struct Name NL fields end NL at pos, with the next position and the next free node id.
def parse_struct(e: Base.Env, pos: Int, ids: Int, doc: Ast.Optional[String]) -> Result[StructAt]
  after_name = try Base.expect(e, pos + 1, "type-name", "a struct name", false)
  cursor = try Base.expect(e, after_name, "NL", "a newline after the struct name", false)
  fields: List[Ast.FieldDecl] = []
  next_id = ids
  looping = true
  while looping
    cursor = Base.skip_newlines(e, cursor)
    kind = e.tokens[cursor].kind
    if kind == "end" or kind == "EOF"
      looping = false
    elsif kind == "name" or kind == "DOC"
      taken = try documented(e, cursor, "field")
      field = try parse_field_decl(e, taken.pos, next_id, taken.doc)
      fields = fields.push(field.node)
      cursor = field.pos
      next_id = field.ids
    else
      return error(Base.found(e, cursor, "a field name or \"end\""))
    end
  end

  close = try expect_end(e, cursor)
  stop = try expect_statement_end(e, close, "a newline after end")
  node = Ast.StructDecl(
    id: next_id,
    name: e.tokens[pos + 1].lexeme,
    name_span: e.tokens[pos + 1].span,
    fields: fields,
    doc: doc,
    record_of: "",
    span: Base.span_from(e, pos, stop),
  )
  return ok(StructAt(node: node, pos: stop, ids: next_id))
end

def parse_type_parameters(e: Base.Env, pos: Int) -> Result[TypeParametersAt]
  names: List[String] = []
  if e.tokens[pos].kind != "left-bracket"
    return ok(TypeParametersAt(names: names, pos: pos))
  end

  cursor = try Base.expect(e, pos + 1, "type-name", "a type parameter", false)
  names = names.push(e.tokens[pos + 1].lexeme)
  while e.tokens[cursor].kind == "comma"
    after = try Base.expect(e, cursor + 1, "type-name", "a type parameter", false)
    names = names.push(e.tokens[cursor + 1].lexeme)
    cursor = after
  end

  cursor = try Base.expect(e, cursor, "right-bracket", "]", false)
  return ok(TypeParametersAt(names: names, pos: cursor))
end

def parse_enum_decl(e: Base.Env, pos: Int, ids: Int, doc: Ast.Optional[String]) -> Result[DeclAt]
  after_name = try Base.expect(e, pos + 1, "type-name", "an enum name", false)
  parameters = try parse_type_parameters(e, after_name)
  cursor = try Base.expect(e, parameters.pos, "NL", "a newline after the enum name", false)
  variants: List[Ast.EnumVariant] = []
  next_id = ids
  looping = true
  while looping
    cursor = Base.skip_newlines(e, cursor)
    kind = e.tokens[cursor].kind
    if kind == "end" or kind == "EOF"
      looping = false
    elsif kind == "type-name" or kind == "DOC"
      taken = try documented(e, cursor, "variant")
      variant = try parse_variant_decl(e, taken.pos, next_id, taken.doc)
      variants = variants.push(variant.node)
      cursor = variant.pos
      next_id = variant.ids
    else
      return error(Base.found(e, cursor, "an enum variant or end"))
    end
  end

  if variants.size == 0
    return error(Base.unexpected(e, cursor, "an enum must declare at least one variant"))
  end

  close = try expect_end(e, cursor)
  stop = try expect_statement_end(e, close, "a newline after end")
  node = Ast.Decl.Enum(
    Ast.EnumDecl(
      id: next_id,
      name: e.tokens[pos + 1].lexeme,
      name_span: e.tokens[pos + 1].span,
      type_parameters: parameters.names,
      variants: variants,
      doc: doc,
      span: Base.span_from(e, pos, stop),
    ),
  )
  return decl_at(node, stop, next_id)
end

def parse_type_alias_decl(e: Base.Env, pos: Int, ids: Int, doc: Ast.Optional[String]) -> Result[DeclAt]
  after_word = try expect_word(e, pos, "type", "")
  after_name = try Base.expect(e, after_word, "type-name", "a type alias name", false)
  parameters = try parse_type_parameters(e, after_name)
  assign = try Base.expect(e, parameters.pos, "assign", "=", false)
  target = try Base.parse_type(e, assign, ids)
  stop = try Base.expect(e, target.pos, "NL", "a newline after the type alias", false)
  node = Ast.Decl.TypeAlias(
    Ast.TypeAliasDecl(
      id: target.ids,
      name: e.tokens[after_word].lexeme,
      name_span: e.tokens[after_word].span,
      type_parameters: parameters.names,
      target: target.node,
      doc: doc,
      span: Base.span_from(e, pos, stop),
    ),
  )
  return decl_at(node, stop, target.ids + 1)
end

def parse_exportable(e: Base.Env, pos: Int, ids: Int) -> Result[DeclAt]
  kind = e.tokens[pos].kind
  absent: Ast.Optional[String] = Ast.Optional.Absent
  if kind == "def"
    return parse_function_decl(e, pos, ids, absent)
  end

  if kind == "struct"
    return parse_struct_decl(e, pos, ids, absent)
  end

  if kind == "enum"
    return parse_enum_decl(e, pos, ids, absent)
  end

  if kind == "name" and e.tokens[pos].lexeme == "type"
    return parse_type_alias_decl(e, pos, ids, absent)
  end

  return error(Base.unexpected(e, pos, "export requires def, struct, enum, type, or a constant"))
end

# A constant starts with a type-name token followed by `=` or `:` (docs/future/44-module-constants.md 44.3). The name
# is checked when it is parsed, so `Limit = 1` is PARSE-CONSTANT-NAME and not a statement.
def constant_start?(e: Base.Env, at: Int) -> Bool
  following = Base.kind_at(e, at + 1)
  return Base.kind_at(e, at) == "type-name" and (following == "assign" or following == "colon")
end

# Whether the declaration after the doc block and the `export` that may start at `at` is a constant: the blank line
# rule lets constants follow each other.
def constant_follows?(e: Base.Env, at: Int) -> Bool
  cursor = at
  if Base.kind_at(e, cursor) == "DOC"
    cursor += 2
  end

  if Base.kind_at(e, cursor) == "export"
    cursor += 1
  end

  return constant_start?(e, cursor)
end

# The name in UPPER_SNAKE_CASE for a CamelCase one (MaxDepth is MAX_DEPTH), or "" when the result is still not a
# constant name (a single letter).
def constant_suggestion(text: String) -> String
  letters = text.split("")
  out: List[String] = []
  index = 0
  while index < letters.size
    code = String.code(letters[index])
    if index > 0 and code >= 65 and code <= 90
      before = String.code(letters[index - 1])
      if (before >= 97 and before <= 122) or (before >= 48 and before <= 57)
        out = out.push("_")
      end
    end

    out = out.push(letters[index])
    index += 1
  end

  snake = out.join("").upcase
  if Base.constant_name?(snake)
    return snake
  end

  return ""
end

def constant_name_help(text: String) -> String
  suggestion = constant_suggestion(text)
  if suggestion == ""
    return "write constant names in capitals with underscores, at least two characters, such as LIMIT"
  end

  return "write constant names in capitals with underscores: use #{suggestion}"
end

# [export] NAME[: Type] = value. name_at is the name token, start the first token (the export, or the name).
def parse_constant_decl(
  e: Base.Env,
  name_at: Int,
  start: Int,
  ids: Int,
  doc: Ast.Optional[String],
  exported: Bool,
) -> Result[DeclAt]
  name = e.tokens[name_at].lexeme
  if !Base.constant_name?(name)
    return error(
      Base.bail(
        e,
        name_at,
        "PARSE-CONSTANT-NAME",
        "\"#{name}\" is not a constant name",
        Base.hint(constant_name_help(name)),
      ),
    )
  end

  type: Ast.Optional[Ast.TypeRef] = Ast.Optional.Absent
  cursor = name_at + 1
  next_id = ids
  if e.tokens[cursor].kind == "colon"
    parsed = try Base.parse_type(e, cursor + 1, next_id)
    type = Ast.Optional.Present(parsed.node)
    cursor = parsed.pos
    next_id = parsed.ids
  end

  assign = try Base.expect(e, cursor, "assign", "\"=\"", false)
  value = try parse_expression(e, assign, next_id)
  stop = try expect_statement_end(e, value.pos, "a newline after the statement")
  node = Ast.Decl.Constant(
    Ast.ConstDecl(
      id: value.ids,
      name: name,
      name_span: e.tokens[name_at].span,
      type: type,
      value: value.node,
      exported: exported,
      doc: doc,
      span: Base.span_from(e, start, stop),
    ),
  )
  return decl_at(node, stop, value.ids)
end

def parse_declaration(e: Base.Env, pos: Int, ids: Int, doc: Ast.Optional[String]) -> Result[DeclAt]
  kind = e.tokens[pos].kind
  if kind == "export" and constant_start?(e, pos + 1)
    return parse_constant_decl(e, pos + 1, pos, ids, doc, true)
  end

  if constant_start?(e, pos)
    return parse_constant_decl(e, pos, pos, ids, doc, false)
  end

  if kind == "export"
    parsed = try parse_exportable(e, pos + 1, ids)
    node = Ast.Decl.Export(
      Ast.ExportDecl(id: parsed.ids, declaration: parsed.node, doc: doc, span: Base.span_from(e, pos, parsed.pos)),
    )
    return decl_at(node, parsed.pos, parsed.ids)
  end

  if kind == "def"
    return parse_function_decl(e, pos, ids, doc)
  end

  if kind == "struct"
    return parse_struct_decl(e, pos, ids, doc)
  end

  if kind == "name" and e.tokens[pos].lexeme == "type"
    return parse_type_alias_decl(e, pos, ids, doc)
  end

  return parse_enum_decl(e, pos, ids, doc)
end

def declaration_start?(e: Base.Env, at: Int) -> Bool
  kind = e.tokens[at].kind
  return (
    kind == "def" or kind == "struct" or kind == "enum" or kind == "export" or constant_start?(e, at) or
    (kind == "name" and e.tokens[at].lexeme == "type") or extern_start?(e, at)
  )
end

# `compute` is a plain name: inside an extern block, before def, it makes the function a compute call.
def compute_start?(e: Base.Env, at: Int) -> Bool
  return e.tokens[at].kind == "name" and e.tokens[at].lexeme == "compute" and Base.kind_at(e, at + 1) == "def"
end

# `extern` is a plain name: it starts a block only at the top level and before a string.
def extern_start?(e: Base.Env, at: Int) -> Bool
  next = Base.kind_at(e, at + 1)
  library = next == "string" or next == "interp-start"
  return e.tokens[at].kind == "name" and e.tokens[at].lexeme == "extern" and library
end

# The position of the interp-end token that closes the interpolated string starting at start (nested strings
# included), or the last token when the string never closes.
def interpolation_end(e: Base.Env, start: Int) -> Int
  depth = 0
  at = start
  while at < e.tokens.size - 1
    kind = e.tokens[at].kind
    if kind == "interp-start"
      depth += 1
    elsif kind == "interp-end"
      depth -= 1
      if depth == 0
        return at
      end
    end

    at += 1
  end

  return at
end

def top_level_help(kind: String) -> String
  if kind == "end"
    return "this end closes nothing: each def, if, while, for, case, struct, enum and do block needs exactly one end"
  end

  if kind == "else" or kind == "elsif"
    return "this else has no matching if"
  end

  return (
    "statements go inside a function: def main() -> Void ... end; " +
    "a file holds only def, struct, enum, type aliases, import, export and constants (NAME = value)"
  )
end

# The two import forms. A string after `import` is the path-first form of earlier versions: the help shows the new one.
# `from` and `as` are plain name tokens read by their text, so a parameter or a function called `from` or `as` still
# works.
def parse_import(e: Base.Env, pos: Int, ids: Int) -> Result[DeclAt]
  kind = Base.kind_at(e, pos + 1)
  if kind == "type-name"
    return parse_import_alias(e, pos, ids)
  elsif kind == "left-brace"
    return parse_import_names(e, pos, ids)
  end

  message = "expected a module alias or \"{\", found #{Base.describe(e.tokens[pos + 1])}"
  if kind == "string"
    return error(Base.unexpected_help(e, pos + 1, message, "write import Alias from \"path\""))
  end

  return error(Base.unexpected(e, pos + 1, message))
end

# The path of an import. A heredoc is a `string` token too; the path takes a "..." literal only.
def expect_import_path(e: Base.Env, pos: Int) -> Result[Int]
  if Base.kind_at(e, pos) == "string" and Base.heredoc?(e.tokens[pos])
    return error(
      Base.unexpected_help(e, pos, "an import path is not a heredoc", "write the path as a \"...\" string literal"),
    )
  end

  return Base.expect(e, pos, "string", "an import path", false)
end

# import Alias from "path"
def parse_import_alias(e: Base.Env, pos: Int, ids: Int) -> Result[DeclAt]
  mixed = ""
  if Base.kind_at(e, pos + 2) == "comma"
    mixed = "write the alias and the names on two import lines"
  end

  after_from = try expect_word(e, pos + 2, "from", mixed)
  after_path = try expect_import_path(e, after_from)
  stop = try Base.expect(e, after_path, "NL", "a newline after import", false)
  alias = Ast.Optional.Present(e.tokens[pos + 1].lexeme)
  node = Ast.Decl.Import(
    Ast.ImportDecl(
      id: ids,
      path: Base.token_text(e.tokens[after_from]),
      alias: alias,
      names: [],
      span: Base.span_from(e, pos, stop),
    ),
  )
  return decl_at(node, stop, ids)
end

# import {A, B as C} from "path"
def parse_import_names(e: Base.Env, pos: Int, ids: Int) -> Result[DeclAt]
  listed = try parse_import_list(e, pos + 2)
  after_from = try expect_word(e, listed.pos, "from", "")
  after_path = try expect_import_path(e, after_from)
  stop = try Base.expect(e, after_path, "NL", "a newline after import", false)
  node = Ast.Decl.Import(
    Ast.ImportDecl(
      id: ids,
      path: Base.token_text(e.tokens[after_from]),
      alias: Ast.Optional.Absent,
      names: listed.nodes,
      span: Base.span_from(e, pos, stop),
    ),
  )
  return decl_at(node, stop, ids)
end

# The position after the name token with this text (from, as). help is "" for none.
def expect_word(e: Base.Env, at: Int, word: String, help: String) -> Result[Int]
  if e.tokens[at].kind == "name" and e.tokens[at].lexeme == word
    return ok(at + 1)
  end

  message = "expected #{word}, found #{Base.describe(e.tokens[at])}"
  if help == ""
    return error(Base.unexpected(e, at, message))
  end

  return error(Base.unexpected_help(e, at, message, help))
end

# The entries after "{": one or more, a trailing comma allowed, then "}".
def parse_import_list(e: Base.Env, at: Int) -> Result[ImportNamesAt]
  if Base.kind_at(e, at) == "right-brace"
    return error(
      Base.unexpected_help(
        e,
        at,
        "expected an imported name, found #{Base.describe(e.tokens[at])}",
        "name at least one export, as in import {name} from \"path\"",
      ),
    )
  end

  nodes: List[Ast.ImportName] = []
  cursor = at
  looping = true
  while looping
    entry = try parse_import_name(e, cursor)
    nodes = nodes.push(entry.node)
    cursor = entry.pos
    kind = Base.kind_at(e, cursor)
    if kind == "comma"
      cursor += 1
      if Base.kind_at(e, cursor) == "right-brace"
        cursor += 1
        looping = false
      end
    elsif kind == "right-brace"
      cursor += 1
      looping = false
    else
      message = "expected \",\" or \"}\", found #{Base.describe(e.tokens[cursor])}"
      return error(Base.unexpected_help(e, cursor, message, "separate names with commas: import {a, b} from \"path\""))
    end
  end

  return ok(ImportNamesAt(nodes: nodes, pos: cursor))
end

# An exported name, then optionally `as` and the local name. The original always comes first, so `{as}` imports a
# function called as.
def parse_import_name(e: Base.Env, at: Int) -> Result[ImportNameAt]
  after_name = try import_word(e, at, "an imported name")
  original = e.tokens[at]
  if e.tokens[after_name].kind == "name" and e.tokens[after_name].lexeme == "as"
    after_local = try import_word(e, after_name + 1, "a local name")
    local = e.tokens[after_name + 1]
    return ok(
      ImportNameAt(
        node: Ast.ImportName(name: original.lexeme, local: local.lexeme, span: original.span, local_span: local.span),
        pos: after_local,
      ),
    )
  end

  return ok(
    ImportNameAt(
      node: Ast.ImportName(
        name: original.lexeme,
        local: original.lexeme,
        span: original.span,
        local_span: original.span,
      ),
      pos: after_name,
    ),
  )
end

# A name or a type name; a name may end in ? or !, as a function does.
def import_word(e: Base.Env, at: Int, description: String) -> Result[Int]
  kind = Base.kind_at(e, at)
  if kind == "name" or kind == "type-name"
    return ok(at + 1)
  end

  return error(Base.found(e, at, description))
end

# `export` followed by a type name and a dot is a re-export. Today `export` is followed only by def, struct, enum, type
# or a constant (a type name and `=` or `:`), so there is no clash.
def reexport_start?(e: Base.Env, at: Int) -> Bool
  return (
    Base.kind_at(e, at) == "export" and Base.kind_at(e, at + 1) == "type-name" and Base.kind_at(e, at + 2) == "dot"
  )
end

# export Alias.name, or export Alias.TypeName: no `as`, no wildcard (docs/grammar/05b-modules.md).
def parse_reexport(e: Base.Env, pos: Int, ids: Int) -> Result[DeclAt]
  alias = e.tokens[pos + 1]
  kind = Base.kind_at(e, pos + 3)
  if kind != "name" and kind != "type-name"
    return error(Base.found(e, pos + 3, "a name to re-export"))
  end

  member = e.tokens[pos + 3]
  stop = try Base.expect(e, pos + 4, "NL", "a newline after export", false)
  node = Ast.Decl.Reexport(
    Ast.ReexportDecl(
      id: ids,
      alias: alias.lexeme,
      name: member.lexeme,
      alias_span: alias.span,
      name_span: member.span,
      span: Base.span_from(e, pos, stop),
    ),
  )
  return decl_at(node, stop, ids)
end

# The blank line rule: right after a declaration other than an import, the next token must not start a declaration, an
# import or a doc block (PARSE-MISSING-BLANK-LINE), before the newlines are skipped. The first doc block of a file,
# followed by a blank line, is the module doc.
def parse_program(e: Base.Env, first_id: Int) -> Result[Ast.Program]
  declarations: List[Ast.Decl] = []
  module_doc: Ast.Optional[String] = Ast.Optional.Absent
  after_declaration = false
  after_constant = false
  cursor = 0
  next_id = first_id
  looping = true
  while looping
    kind = e.tokens[cursor].kind
    if (
      after_declaration and
      (declaration_start?(e, cursor) or kind == "import" or kind == "DOC") and
      !(after_constant and constant_follows?(e, cursor))
    )
      return error(
        Base.bail(
          e,
          cursor,
          "PARSE-MISSING-BLANK-LINE",
          "expected a blank line after the end of a declaration",
          Diag.Help.NoHelp,
        ),
      )
    end

    cursor = Base.skip_newlines(e, cursor)
    kind = e.tokens[cursor].kind
    after_declaration = false
    after_constant = false
    if kind == "EOF"
      looping = false
    elsif (
      kind == "DOC" and
      declarations.size == 0 and
      doc_block(e.tokens[cursor]).next == "blank" and
      module_doc_absent?(module_doc)
    )
      module_doc = Ast.Optional.Present(doc_block(e.tokens[cursor]).text)
      cursor += 1
    elsif kind == "import"
      parsed = try parse_import(e, cursor, next_id)
      declarations = declarations.push(parsed.node)
      cursor = parsed.pos
      next_id = parsed.ids
    elsif reexport_start?(e, cursor)
      parsed = try parse_reexport(e, cursor, next_id)
      declarations = declarations.push(parsed.node)
      cursor = parsed.pos
      next_id = parsed.ids
    elsif extern_start?(e, cursor)
      block = try parse_extern_block(e, cursor, next_id)
      declarations = declarations.concat(block.nodes)
      cursor = block.pos
      next_id = block.ids
      after_declaration = true
    elsif declaration_start?(e, cursor) or kind == "DOC"
      taken = try documented(e, cursor, "declaration")
      parsed = try parse_declaration(e, taken.pos, next_id, taken.doc)
      declarations = declarations.push(parsed.node)
      cursor = parsed.pos
      next_id = parsed.ids
      after_declaration = true
      after_constant = constant?(parsed.node)
    else
      return error(
        Base.bail(
          e,
          cursor,
          "PARSE-TOP-LEVEL-STATEMENT",
          (
            "expected a top-level declaration (def, struct, enum, type alias, constant, or import), " +
            "found #{Base.describe(e.tokens[cursor])}"
          ),
          Base.hint(top_level_help(kind)),
        ),
      )
    end
  end

  return ok(
    Ast.Program(id: next_id, declarations: declarations, module_doc: module_doc, span: Base.span_from(e, 0, cursor)),
  )
end

def constant?(decl: Ast.Decl) -> Bool
  case decl
    Ast.Decl.Constant(node) -> return true
    _ -> return false
  end
end

def module_doc_absent?(doc: Ast.Optional[String]) -> Bool
  case doc
    Ast.Optional.Absent -> return true
    _ -> return false
  end
end
