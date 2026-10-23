## What a check takes from an earlier check of the same program (Checker.check_query_reusing): the state that the
## modules which did not change left behind. A module that did not change, with everything it imports
## (analysis/cache.agc decides that from the texts and the shapes), is checked to the same result again: its
## constants, the types of its nodes and what its method calls resolved to depend on nothing else. So the nodes of
## such a module keep their entries and the checker skips its constants and its functions. The state built here holds
## the entries of the unchanged modules only, so it is the state of a run that checked them, in the order of the ids
## rather than of the checks.
##
## The ids of a module are the same in both programs (a kept file keeps its tree and so its ids; a module whose ids
## moved is checked again). The receivers of rewritten constant members are the exception: they sit at `receivers`
## plus the id of the call, and `receivers` is the highest id of the parser, which grows with every file parsed again,
## so those entries are moved by the difference.

import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import T from "../syntax/types"
import State from "check_state"

## What is taken: the state with the entries of the modules in `clean`, the types of their constants by linked name,
## and those modules (the ones asked for that the earlier program also has, with the same ids and constants).
export struct Taken
  st: State.St
  constants: Map[String, T.Type]
  clean: Set[String]
end

# The ids of a module: first <= id < next.
struct Stretch
  first: Int
  next: Int
end

# The modules that are taken: their ids, and the types of their constants.
struct Plan
  stretches: List[Stretch]
  clean: Set[String]
  constants: Map[String, T.Type]
end

## Takes from `old`, the state that checked `before`, the entries of the modules of `wanted` that `linked` has as
## `before` has them. `old_constants` are the types of the constants of `before` by linked name.
export def take(
  linked: Linker.Linked,
  before: Linker.Linked,
  old: State.St,
  old_constants: Map[String, T.Type],
  wanted: Set[String],
) -> Taken
  # An earlier result that does not cover its own program is not trusted.
  usable: Set[String] = Set.new([])
  if old.types.size >= before.ids
    usable = wanted
  end
  plan = planned(linked, before, old_constants, usable)
  st = State.fresh().with(
    types: types_of(linked, before, old.types, plan.stretches),
    resolved: moved_resolved(linked, before, old.resolved, plan.stretches),
    bound: moved_bound(linked, before, old.bound, plan.stretches),
    bodies: moved_bodies(linked, before, old.bodies, plan.stretches),
    step_tries: moved_tries(linked, before, old.step_tries, plan.stretches),
  )
  return Taken(st: st, constants: plan.constants, clean: plan.clean)
end

# The modules of `wanted` that `before` has with the same ids and the types of all their constants, ordered by ids.
def planned(
  linked: Linker.Linked,
  before: Linker.Linked,
  old_constants: Map[String, T.Type],
  wanted: Set[String],
) -> Plan
  earlier: Map[String, Linker.LinkedModule] = {}
  for module in before.modules
    earlier = earlier.put(module.key, module)
  end
  stretches: List[Stretch] = []
  clean: List[String] = []
  constants: Map[String, T.Type] = {}
  for module in linked.modules
    if !wanted.include?(module.key) or !earlier.has_key?(module.key)
      next
    end
    old = earlier[module.key]
    if old.first_id != module.first_id or old.next_id != module.next_id
      next
    end
    found = constants_of(module, old_constants)
    if found.ok?
      for name in found.unwrap!.keys
        constants = constants.put(name, found.unwrap![name])
      end
      stretches = stretches.push(Stretch(first: module.first_id, next: module.next_id))
      clean = clean.push(module.key)
    end
  end
  ordered = stretches.sort_by do |stretch: Stretch| stretch.first end
  return Plan(stretches: joined(ordered), clean: Set.new(clean), constants: constants)
end

# The stretches with those that touch one another made one: a walk that kept its files leaves a few long stretches, so
# the pieces that are copied and searched are few.
def joined(ordered: List[Stretch]) -> List[Stretch]
  found: List[Stretch] = []
  for stretch in ordered
    last = found.size - 1
    if last >= 0 and found[last].next == stretch.first
      found = found.set(last, Stretch(first: found[last].first, next: stretch.next))
    else
      found = found.push(stretch)
    end
  end
  return found
end

# The types that `old_constants` holds for the constants of `module`, or an error when it lacks one.
def constants_of(module: Linker.LinkedModule, old_constants: Map[String, T.Type]) -> Result[Map[String, T.Type]]
  found: Map[String, T.Type] = {}
  for decl in module.declarations
    case decl
      Ast.Decl.Constant(node) ->
        type = try old_constants.get(node.name)
        found = found.put(node.name, type)
      _ -> found = found
    end
  end
  return ok(found)
end

# The types of the new program: the old types of the stretches, at the same ids and again at the ids of their
# receivers, and no type anywhere else.
def types_of(linked: Linker.Linked, before: Linker.Linked, old: List[T.Type], stretches: List[Stretch]) -> List[T.Type]
  types: List[T.Type] = []
  at = 0
  for stretch in stretches
    types = types.concat(State.no_types(stretch.first - at))
    types = types.concat(old.drop(stretch.first).take(stretch.next - stretch.first))
    at = stretch.next
  end
  if linked.receivers >= 0
    types = types.concat(State.no_types(linked.receivers - at))
    at = linked.receivers
    for stretch in stretches
      types = types.concat(State.no_types(linked.receivers + stretch.first - at))
      if before.receivers >= 0
        types = types.concat(old.drop(before.receivers + stretch.first).take(stretch.next - stretch.first))
      else
        types = types.concat(State.no_types(stretch.next - stretch.first))
      end
      at = linked.receivers + stretch.next
    end
  end
  return types.concat(State.no_types(linked.ids - at))
end

# The id that an old id has in the new program when a stretch holds it, else -1.
def placed(linked: Linker.Linked, before: Linker.Linked, stretches: List[Stretch], id: Int) -> Int
  local = id
  shift = 0
  if before.receivers >= 0 and id >= before.receivers
    if linked.receivers < 0
      return -1
    end
    local = id - before.receivers
    shift = linked.receivers
  end
  low = 0
  high = stretches.size
  while low < high
    middle = (low + high) / 2
    if local < stretches[middle].first
      high = middle
    elsif local >= stretches[middle].next
      low = middle + 1
    else
      return local + shift
    end
  end
  return -1
end

def moved_resolved(
  linked: Linker.Linked,
  before: Linker.Linked,
  old: Map[Int, State.Resolved],
  stretches: List[Stretch],
) -> Map[Int, State.Resolved]
  found: Map[Int, State.Resolved] = {}
  for id in old.keys
    at = placed(linked, before, stretches, id)
    if at >= 0
      found = found.put(at, old[id])
    end
  end
  return found
end

def moved_bound(
  linked: Linker.Linked,
  before: Linker.Linked,
  old: Map[Int, List[T.Type]],
  stretches: List[Stretch],
) -> Map[Int, List[T.Type]]
  found: Map[Int, List[T.Type]] = {}
  for id in old.keys
    at = placed(linked, before, stretches, id)
    if at >= 0
      found = found.put(at, old[id])
    end
  end
  return found
end

def moved_bodies(
  linked: Linker.Linked,
  before: Linker.Linked,
  old: Map[Int, String],
  stretches: List[Stretch],
) -> Map[Int, String]
  found: Map[Int, String] = {}
  for id in old.keys
    at = placed(linked, before, stretches, id)
    if at >= 0
      found = found.put(at, old[id])
    end
  end
  return found
end

def moved_tries(
  linked: Linker.Linked,
  before: Linker.Linked,
  old: Set[Int],
  stretches: List[Stretch],
) -> Set[Int]
  found: List[Int] = []
  for id in old.to_a
    at = placed(linked, before, stretches, id)
    if at >= 0
      found = found.push(at)
    end
  end
  return Set.new(found)
end
