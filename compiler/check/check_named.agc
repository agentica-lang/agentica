## Named arguments of a call (`f(gen, verbose: true)`): each fills the parameter of its name, and the call becomes a
## positional one with the parameters it leaves out at their defaults (defaults.agc binds them, and the lowering reads
## the slots this records).

import Ast from "../syntax/ast"
import Suggest from "../syntax/suggest"
import State from "check_state"
import Defaults from "defaults"

## A call with its named arguments bound, and the state with its slots recorded.
export struct Bound
  st: State.St
  node: Ast.Call
end

## Binds the named arguments of node to the parameters `names` of a callee with that shape. shown is the callee as the
## diagnostics name it, and skipped the parameters before the ones written in the parentheses (1 for the receiver of a
## method call), which a help never lists. A name with no parameter is CHECK-UNKNOWN-ARGUMENT and a parameter given
## twice (by name, or by position and by name) CHECK-REPEATED-ARGUMENT, at that argument; a parameter with no default
## and no argument is CHECK-MISSING-ARGUMENT at the call.
export def bind(
  cx: State.Cx,
  st: State.St,
  node: Ast.Call,
  names: List[String],
  shape: Defaults.Shape,
  shown: String,
  skipped: Int,
) -> Result[Bound]
  binding = Defaults.bind(names, shape, node.args, node.named)
  code = binding.code
  if code == "CHECK-UNKNOWN-ARGUMENT"
    arg = node.named[binding.at]
    listed = names.drop(skipped).filter do |name: String| name != "_" end
    help = "#{shown} takes #{listed.join(", ")}"
    if listed.size == 0
      help = "#{shown} takes no arguments by name"
    end

    case Suggest.did_you_mean(arg.name, listed)
      some(text) -> help = text
      none -> help = help
    end

    message = "#{shown} has no parameter \"#{arg.name}\""
    return error(State.fail_help(cx, st, code, message, arg.span, help))
  elsif code == "CHECK-REPEATED-ARGUMENT"
    arg = node.named[binding.at]
    message = "the argument \"#{arg.name}\" of #{shown} is given twice"
    help = "give each argument once, by position or by name"
    return error(State.fail_help(cx, st, code, message, arg.span, help))
  elsif code == "CHECK-MISSING-ARGUMENT"
    message = "#{shown} is missing the argument \"#{binding.name}\""
    help = "give it by position or by name: #{binding.name}: value"
    return error(State.fail_help(cx, st, code, message, node.span, help))
  elsif code != ""
    message = "#{shown} takes at most #{shape.total - skipped} argument(s), found #{node.args.size - skipped}"
    return error(State.fail(cx, st, code, message, node.span))
  end

  ok(Bound(st: State.record_slots(st, node.id, binding.slots), node: Defaults.bound(node, binding.slots)))
end
