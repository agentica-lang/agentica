## The named arguments of calls as uses of parameters, for `type-at` and `refs` (docs/grammar/06b-builtins.md): the
## `verbose` of `check(gen, verbose: true)` names the parameter `verbose` of the function `check`. The checker decided
## which parameter each argument of a call fills (`Checked.slots`, by the id of the call), so nothing here matches a
## name by its text alone: a call that did not check, a call of a builtin and the fields of `error(...)` (which are not
## parameters) have no slots of a function of the program and give nothing.
##
## Each module is walked once, with a worklist and no recursion, so a deep tree cannot reach the limit of VM calls.

import Defaults from "../check/defaults"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import Walk from "../syntax/ast_walk"
import Source from "../syntax/source"
import T from "../syntax/types"
import At from "at"
import Locals from "locals"

## The parameter that a named argument stands for: `local` is the parameter, as query/locals.agc gives it, `module` the
## module that declares its function and `site` the name of the argument at the call.
struct Named
  local: Locals.Local
  module: Linker.LinkedModule
  site: Source.Span
end

## A named argument at a call of the function of a parameter: `module` holds the call, `span` is the name.
struct Use
  module: Linker.LinkedModule
  span: Source.Span
end

## The parameter that the name of a named argument at `offset` in the root file of `modules` stands for, or `none`.
## `slots` is `Checked.slots` and `bound` is `Checked.bound`, which give the type of the parameter.
def at(
  modules: List[Linker.LinkedModule],
  slots: Map[Int, List[Int]],
  bound: Map[Int, List[T.Type]],
  offset: Int,
) -> Optional[Named]
  for call in calls_of(modules[0])
    index = 0
    while index < call.named.size
      site = name_span(call.named[index])
      if At.holds?(site, offset)
        case parameter_of(modules, slots, call, index)
          some(found) ->
            param = found.function.params[found.index]
            local = Locals.function_parameter(bound, param)
            return none if T.unknown?(local.type)

            return some(Named(local: local, module: found.module, site: site))
          none -> return none
        end
      end

      index += 1
    end
  end

  none
end

## The named arguments of every module that fill `local`, when it is a parameter of a function that `module` declares;
## none for any other local (a block parameter has no name a call could give). In the order of `modules` and, within
## one module, of the walk.
def uses(
  modules: List[Linker.LinkedModule],
  slots: Map[Int, List[Int]],
  module: Linker.LinkedModule,
  local: Locals.Local,
) -> List[Use]
  out: List[Use] = []
  return out if local.kind != "parameter"

  case declared(module, local)
    none -> out
    some(found) ->
      for caller in modules
        for call in calls_of(caller)
          next if call.name != found.function.name

          index = 0
          while index < call.named.size
            if slot_of(slots, call, index) == found.index
              out = out.push(Use(module: caller, span: name_span(call.named[index])))
            end

            index += 1
          end
        end
      end

      out
  end
end

private

# The parameter `index` of the function `function`, which `module` declares.
struct Param
  module: Linker.LinkedModule
  function: Ast.FunctionDecl
  index: Int
end

# The function of `module` whose parameter `local` is, with the index of the parameter.
def declared(module: Linker.LinkedModule, local: Locals.Local) -> Optional[Param]
  offset = local.name_span.start.offset
  for declaration in module.declarations
    case declaration
      Ast.Decl.Function(node) ->
        index = 0
        while index < node.params.size
          if node.params[index].name_span.start.offset == offset
            return some(Param(module: module, function: node, index: index))
          end

          index += 1
        end

      _ -> next
    end
  end

  none
end

# The parameter of a function of the program that the named argument `index` of `call` fills, by the slots the checker
# recorded. The name of the parameter is the name of the argument, since the checker bound it by that name.
def parameter_of(
  modules: List[Linker.LinkedModule],
  slots: Map[Int, List[Int]],
  call: Ast.Call,
  index: Int,
) -> Optional[Param]
  param = slot_of(slots, call, index)
  return none if param < 0

  for module in modules
    for declaration in module.declarations
      case declaration
        Ast.Decl.Function(node) ->
          if node.name == call.name and param < node.params.size and node.params[param].name == call.named[index].name
            return some(Param(module: module, function: node, index: param))
          end

        _ -> next
      end
    end
  end

  none
end

# The parameter that the named argument `index` of `call` fills, or -1 when the checker recorded no slots for the call.
# The slots are in source order: the positional arguments (a piped value first), the named ones, then a trailing block.
def slot_of(slots: Map[Int, List[Int]], call: Ast.Call, index: Int) -> Int
  filled = slots.get(call.id).unwrap_or([])
  positional = call.args.size
  if Defaults.trailing_block?(call.args)
    positional -= 1
  end

  at = positional + index
  return -1 if at >= filled.size

  filled[at]
end

# The name of a named argument, which its span starts with.
def name_span(arg: Ast.NamedArg) -> Source.Span
  start = arg.span.start
  stop = Source.Position(
    offset: start.offset + arg.name.length,
    line: start.line,
    column: start.column + arg.name.length,
  )

  Source.Span(start: start, stop: stop)
end

# The calls with named arguments in the functions and constants of `module`, parameter defaults included.
def calls_of(module: Linker.LinkedModule) -> List[Ast.Call]
  work: List[Walk.Node] = []
  for declaration in module.declarations
    case declaration
      Ast.Decl.Function(node) ->
        for param in node.params
          case param.default
            some(value) -> work = work.push(Walk.Node.Expr(value))
            none -> next
          end
        end

        work = work.concat(node.body.map do |stmt: Ast.Stmt| Walk.Node.Stmt(stmt) end)
      Ast.Decl.Constant(node) -> work = work.push(Walk.Node.Expr(node.value))
      _ -> next
    end
  end

  out: List[Ast.Call] = []
  at = 0
  while at < work.size
    node = work[at]
    at += 1
    case node
      Walk.Node.Expr(Ast.Expr.Call(call)) ->
        if call.named.size > 0
          out = out.push(call)
        end

      _ -> out = out
    end

    work = work.concat(Walk.children(node))
  end

  out
end
