## The functions of the `extern module "NAME"` blocks (#1149): the types that cross between the program and the C code
## of a native module. A type crosses when it is Int, Float, Bool, String or Bytes, Void where the language allows it,
## a List, Optional or Result of a crossing type, a Map with Int, String or Bytes keys and crossing values, or a struct
## or enum of the program that is not generic and whose fields or payloads cross. Anything else is CHECK-NATIVE-TYPE at
## the type in the signature, and so is a second user type of the same bare name in the functions of one block, since
## the module knows its types by that name. The checker records the type that each written type stands for, by the node
## id of the type, for the parameters and results of these functions and for the fields and payloads of the user types
## that cross: the lowering writes the canonical signature and the shape of each user type from them
## (lower_native.agc).

import {ENUMS} from "../catalog/builtins"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import T from "../syntax/types"
import State from "check_state"
import Types from "check_types"

# The kinds of type that cross as they are, and the keys of a Map that crosses (the keys of vm/map.c).
PLAIN = Set.new(["Int", "Float", "Bool", "String", "Bytes", "Void"])
KEYS = Set.new(["Int", "String", "Bytes"])
# The kinds whose item crosses when the item does.
WRAPPERS = Set.new(["List", "Optional", "Result"])
CROSSING_HELP = (
  "a native module takes and returns Int, Float, Bool, String, Bytes, Void as the result, a List, Optional or " +
  "Result of them, a Map with Int, String or Bytes keys, and the structs and enums of the program that are not generic"
)

# The types written in the fields of a struct or the payloads of an enum, in order, and the file that declares it.
struct Written
  file: String
  refs: List[Ast.TypeRef]
end

# The walk over the functions of one block: the checker state with the recorded types, the user types already walked,
# and the linked name of each bare name that crosses.
struct Walk
  st: State.St
  seen: Set[String]
  named: Map[String, String]
end

# A user type that a walk reaches: the walk with it, and the types of its fields or payloads, none when it was walked
# already.
struct Reached
  walk: Walk
  types: List[T.Type]
end

## The state with the types of the functions of the extern module blocks recorded, for the modules that are not clean
## (a clean module keeps the types of the check it was taken from); the first problem is CHECK-NATIVE-TYPE.
export def check_all(
  cx: State.Cx,
  st: State.St,
  modules: List[Linker.LinkedModule],
  clean: Set[String],
) -> Result[State.St]
  written = written_types(modules)
  current = st
  for module in modules
    if clean.include?(module.key)
      next
    end

    here = cx.with(file: module.file)
    # One walk per block: a module's library, as written, names it.
    blocks: Map[String, Walk] = {}
    for decl in module.declarations
      case decl
        Ast.Decl.Function(node) ->
          case node.native
            some(native) if native.module ->
              unseen: Set[String] = Set.new([])
              walk = blocks.get(native.library, Walk(st: current, seen: unseen, named: {})).with(st: current)
              walk = try check_function(here, walk, node, written)
              blocks = blocks.put(native.library, walk)
              current = walk.st
            _ -> next
          end

        _ -> next
      end
    end
  end

  return ok(current)
end

# The field types of each struct and the payload types of each enum of the program, by linked name.
def written_types(modules: List[Linker.LinkedModule]) -> Map[String, Written]
  found: Map[String, Written] = {}
  for module in modules
    for decl in module.declarations
      case decl
        Ast.Decl.Struct(node) ->
          refs = node.fields.map do |field: Ast.FieldDecl| field.type end
          found = found.put(node.name, Written(file: module.file, refs: refs))
        Ast.Decl.Enum(node) ->
          refs: List[Ast.TypeRef] = []
          for variant in node.variants
            refs = refs.concat(variant.payload_types)
          end

          found = found.put(node.name, Written(file: module.file, refs: refs))
        _ -> next
      end
    end
  end

  return found
end

def check_function(cx: State.Cx, walk: Walk, node: Ast.FunctionDecl, written: Map[String, Written]) -> Result[Walk]
  current = walk
  for param in node.params
    current = try check_ref(cx, current, param.type, false, written)
  end

  return check_ref(cx, current, node.result, true, written)
end

# The walk with the type written at ref resolved, recorded at its id and checked, together with the user types it
# reaches, which are walked from a list rather than by recursion, so a recursive type ends.
def check_ref(cx: State.Cx, walk: Walk, ref: Ast.TypeRef, result: Bool, written: Map[String, Written]) -> Result[Walk]
  type = try Types.resolve_type(cx, walk.st, ref, result)
  current = walk.with(st: State.record_type(walk.st, ref.id, type))
  pending = [type]
  at = 0
  while at < pending.size
    item = pending[at]
    at += 1
    tag = T.tag(item)
    if PLAIN.include?(tag)
      next
    end

    if WRAPPERS.include?(tag)
      pending = pending.push(T.item(item))
    elsif tag == "Map" and KEYS.include?(T.tag(T.key(item)))
      pending = pending.push(T.value(item))
    elsif user_type?(cx, item)
      reached = try user_type(cx, current, ref, T.name(item), written)
      current = reached.walk
      pending = pending.concat(reached.types)
    else
      # A nested type is named with the type of the signature that holds it.
      where = ""
      if item != type
        where = " (in #{T.to_text(type)})"
      end

      return error(
        State.fail_help(
          cx,
          current.st,
          "CHECK-NATIVE-TYPE",
          "#{T.to_text(item)} does not cross to a native module#{where}",
          ref.span,
          CROSSING_HELP,
        ),
      )
    end
  end

  return ok(current)
end

# Whether the type is a struct or an enum of the program with no type arguments: a struct whose fields the program
# declares (a builtin record has none), or an enum that is not builtin.
def user_type?(cx: State.Cx, type: T.Type) -> Bool
  if T.args(type).size > 0
    return false
  end

  case type
    T.Type.Struct(name, _) -> return cx.field_sites.has_key?(name)
    T.Type.Enum(name, _) -> return !ENUMS.has_key?(name)
    _ -> return false
  end
end

# The user type NAME, reached from the signature type at ref: CHECK-NATIVE-TYPE there when another user type of the
# block has its bare name, else its field or payload types, each recorded at the id of the type written for it.
def user_type(
  cx: State.Cx,
  walk: Walk,
  ref: Ast.TypeRef,
  name: String,
  written: Map[String, Written],
) -> Result[Reached]
  if walk.seen.include?(name)
    return ok(Reached(walk: walk, types: []))
  end

  bare = T.display_name(name)
  if walk.named.has_key?(bare)
    return error(
      State.fail_help(
        cx,
        walk.st,
        "CHECK-NATIVE-TYPE",
        "two types named #{bare} cross to the native module",
        ref.span,
        "the module knows its types by their bare names: rename one of them",
      ),
    )
  end

  st = walk.st
  types: List[T.Type] = []
  declared = written[name]
  for field in declared.refs
    type = try Types.resolve_type(cx.with(file: declared.file), st, field, false)
    st = State.record_type(st, field.id, type)
    types = types.push(type)
  end

  crossed = Walk(st: st, seen: walk.seen.add(name), named: walk.named.put(bare, name))
  return ok(Reached(walk: crossed, types: types))
end
