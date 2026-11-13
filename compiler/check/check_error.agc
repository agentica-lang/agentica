## The named arguments of error(...) and Result.Err(...): the fields of the Error record that the call builds, and the
## rule for a kind written as a literal (docs/grammar/06-semantics.md, "Result and propagation").

import Ast from "../syntax/ast"
import Source from "../syntax/source"
import T from "../syntax/types"
import State from "check_state"

## Why a kind is not a dotted name, or "" when it is one: segments of a-z, 0-9 and _, each starting with a letter,
## joined by single dots (`db`, `db.constraint`, `io.not_found`).
def kind_problem(kind: String) -> String
  shape = "a kind is a dotted name such as db.constraint: parts of a-z, 0-9 and _ that start with a letter"
  return shape if kind == ""

  for part in kind.split(".")
    return shape if part == "" or !KIND_START.include?(part.slice(0, 1))

    for character in part.split("")
      return shape if !KIND_REST.include?(character)
    end
  end

  ""
end

## CHECK-ERROR-KIND when expr is a text literal that is not a dotted name. A computed kind is not checked: building an
## error must never fail.
def check_kind_literal(cx: State.Cx, st: State.St, expr: Ast.Expr) -> Result[Void]
  case expr
    Ast.Expr.Literal(literal) ->
      case literal.value
        Ast.LitValue.Text(text) ->
          problem = kind_problem(text)
          message = "\"#{text}\" is not an error kind"
          return error(State.fail_help(cx, st, "CHECK-ERROR-KIND", message, literal.span, problem)) if problem != ""

          ok()
        _ -> ok()
      end

    _ -> ok()
  end
end

## Checks the named arguments of an error(...) call whose first argument has the type `first`. An Error first argument
## takes none (CHECK-ARITY at the first name); otherwise each name is one of kind, code, details and cause, given once,
## with a value of its field's type: code an Int and cause an Error, which the call wraps in some(...).
def check_named(cx: State.Cx, st: State.St, node: Ast.Call, first: T.Type) -> Result[State.St]
  return ok(st) if node.named.size == 0

  if T.error?(first)
    help = "wrap it: error(\"text\", kind: ..., cause: e), or change it: e.with(kind: ...)"
    message = "error(e) with an Error takes no named argument"
    return error(State.fail_help(cx, st, "CHECK-ARITY", message, name_span(node.named[0]), help))
  end

  current = st
  seen: Set[String] = Set.new([])
  for arg in node.named
    span = name_span(arg)
    if arg.name == "message" or seen.include?(arg.name)
      return error(State.fail(cx, current, "CHECK-DUPLICATE-FIELD", "field \"#{arg.name}\" is given twice", span))
    end

    if !NAMED_FIELDS.include?(arg.name)
      help = "error(...) takes the named arguments #{NAMED_FIELDS.join(", ")}"
      message = "error has no field \"#{arg.name}\""
      return error(State.fail_help(cx, current, "CHECK-UNKNOWN-FIELD", message, span, help))
    end

    seen = seen.add(arg.name)
    current = try check_value(cx, current, arg)
  end

  ok(current)
end

private

# The fields a named argument may set, and the type of each value. code and cause are stored as some(value).
NAMED_FIELDS = ["kind", "code", "details", "cause"]
KIND_START = Set.new("abcdefghijklmnopqrstuvwxyz".split(""))
KIND_REST = Set.new("abcdefghijklmnopqrstuvwxyz0123456789_".split(""))

def check_value(cx: State.Cx, st: State.St, arg: Ast.NamedArg) -> Result[State.St]
  wanted = T.Type.Int
  if arg.name == "kind"
    try check_kind_literal(cx, st, arg.value)
    wanted = T.Type.String
  elsif arg.name == "details"
    wanted = T.Type.Map(T.Type.String, T.Type.String)
  elsif arg.name == "cause"
    wanted = T.error_type()
  end

  if (arg.name == "code" or arg.name == "cause") and some_call?(arg.value)
    span = Ast.expr_span(arg.value)
    message = "expected #{T.to_text(wanted)}, found Optional[#{T.to_text(wanted)}]"
    help = "write the value alone, as in #{arg.name}: x; the call stores it as some(x)"
    return error(State.fail_help(cx, st, "CHECK-TYPE-MISMATCH", message, span, help))
  end

  out = try State.expr(cx, st, arg.value, wanted)
  ok(out.st)
end

def some_call?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Call(call) -> call.name == "some"
    _ -> false
  end
end

# The span of the name of a named argument, which starts it.
def name_span(arg: Ast.NamedArg) -> Source.Span
  start = arg.span.start
  size = arg.name.length
  stop = Source.Position(offset: start.offset + size, line: start.line, column: start.column + size)
  Source.Span(start: start, stop: stop)
end
