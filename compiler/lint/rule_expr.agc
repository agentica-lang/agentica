## The rules that read one expression: a Bool compared with a literal, a pipe of one step, three nested calls and text
## joined with `+` and `to_s`.

import {ENTRIES} from "../catalog/builtins"
import Tables from "../check/check_tables"
import RubyForm from "../check/ruby_form"
import Problems from "../diagnostics/problem"
import Ast from "../syntax/ast"
import Rules from "rules"
import Shape from "shape"

## The suggestions for `expr`. `chained` is true when it is the first operand of a pipe, of a `+` chain or of a plain
## call: the expression above it judged the whole chain, so it must not be judged again as a chain of its own.
export def suggestions(file: String, expr: Ast.Expr, chained: Bool) -> List[Problems.Problem]
  case expr
    Ast.Expr.Binary(node) -> return binary(file, node, chained)
    Ast.Expr.Call(node) -> return single_pipe(file, node, chained).concat(nested_call(file, node, chained))
    _ -> return []
  end
end

def binary(file: String, node: Ast.Binary, chained: Bool) -> List[Problems.Problem]
  found: List[Problems.Problem] = []
  if (node.op == "equal" or node.op == "not-equal") and (Shape.flag?(node.left) or Shape.flag?(node.right))
    found = found.push(Rules.at(file, Rules.BOOL_COMPARE, node.span))
  end

  if node.op == "plus" and !chained and joins_text?(node)
    found = found.push(Rules.at(file, Rules.TO_S_CONCAT, node.span))
  end

  return found
end

# A `+` chain with a piece of literal text and a `to_s` call: the join that interpolation writes better. Two Strings
# added with no `to_s` are left alone, since a few sentence-sized pieces are allowed to wrap a long text.
def joins_text?(node: Ast.Binary) -> Bool
  operands = Shape.plus_operands(Ast.Expr.Binary(node))
  literal = operands.any? do |piece: Ast.Expr| Shape.text?(piece) end
  converted = operands.any? do |piece: Ast.Expr| Shape.to_s?(piece) end
  return literal and converted
end

# `x |> f()` where x is not itself the result of a pipe.
def single_pipe(file: String, node: Ast.Call, chained: Bool) -> List[Problems.Problem]
  if !node.piped or chained or node.args.size == 0 or piped_call?(node.args[0])
    return []
  end

  return [Rules.at(file, Rules.SINGLE_PIPE, node.span)]
end

# `h(f(g(x)))`: a plain call whose first argument is a plain call whose first argument is a call, which a pipe writes
# from the inside out. The two outer calls become the steps, and a pipe goes into the program's own functions (the
# style guide), so a builtin there is left alone: piping to one with a method form is CHECK-PIPE-METHOD, and `ok`,
# `error`, `some` and `puts` read better as calls.
def nested_call(file: String, node: Ast.Call, chained: Bool) -> List[Problems.Problem]
  if chained or !step?(node)
    return []
  end

  case node.args[0]
    Ast.Expr.Call(middle) ->
      if step?(middle) and call?(middle.args[0])
        return [Rules.at(file, Rules.NESTED_CALL, node.span)]
      end

      return []
    _ -> return []
  end
end

def call?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Call(_) -> return true
    _ -> return false
  end
end

# A plain call with a first argument that a pipe could pass, to a function that is not a builtin. A name such as
# `ROWS.concat` is a method of a constant, whose receiver is not the first argument.
def step?(node: Ast.Call) -> Bool
  if node.piped or node.args.size == 0 or ENTRIES.has_key?(node.name) or Tables.method_aliases().has_key?(node.name)
    return false
  end

  return RubyForm.method_key(node.name) == "" and !constant_receiver?(node.name)
end

# Whether the part of `name` before its first `.` is written as a constant: capitals and no small letter.
def constant_receiver?(name: String) -> Bool
  case name.index_of(".")
    some(dot) ->
      receiver = name.slice(0, dot)
      return receiver == receiver.upcase and receiver != receiver.downcase
    none -> return false
  end
end

# Whether the expression is a piped call, as `x |> try f()` is too.
def piped_call?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Call(node) -> return node.piped
    Ast.Expr.Try(wrapper) -> return piped_call?(wrapper.operand)
    _ -> return false
  end
end
