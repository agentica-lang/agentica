## The type checker: takes a linked program and gives the type of every expression and the
## resolution of every method call, or the first problem. The declarations are registered first (enums, structs,
## variants, functions, main), then the module constants are ordered and checked, then each function is checked in
## program order, file by file.

import {ENUMS, RECORDS} from "../catalog/builtins"
import Failure from "../diagnostics/problem"
import Env from "../modules/link_env"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import T from "../syntax/types"
import Constants from "check_const"
import DefaultChecks from "check_defaults"
import Expr from "check_expr"
import Help from "check_help"
import Register from "check_register"
import State from "check_state"
import Statements from "check_stmt"
import Reuse from "check_reuse"
import Prelude from "prelude_files"

## What checking learned: the type of each expression and block, in a list indexed by node id (Unknown for a node that
## has none: node ids are dense, so a list is faster than a Map to write and read), what each method call or field
## access resolved to, by node id (the lowering reads them), and the linked names of the module constants in
## initialization order (the lowering reads that too, and does not order them again). prelude is the files of the
## compiler prelude that the program calls (prelude_files.agc), checked with it: the lowering adds them to the files of
## the program. bodies is the prelude function each call of a prelude builtin runs, by id of the call. step_tries is
## the id of each `try` in the block of a Lazy method (State.St.step). bound is the types that each name binding
## introduced, by node id (State.record_bound), for `agentica type-at`. constant_types is the type of each constant by
## linked name (a later check of the same program takes them with the entries of the modules it does not check again).
export struct Checked
  types: List[T.Type]
  resolved: Map[Int, State.Resolved]
  constants: List[String]
  constant_types: Map[String, T.Type]
  prelude: List[Linker.LinkedModule]
  bodies: Map[Int, String]
  step_tries: Set[Int]
  bound: Map[Int, List[T.Type]]
end

## What `check_recovering` learned: the types of the functions that passed, and the problems of those that did not with
## their linked names (`failed`, in the same order).
export struct Recovered
  checked: Checked
  problems: List[Failure.Problem]
  failed: List[String]
end

## The result of `check_recovering`: the program as far as it checks, or the one failure that leaves nothing to
## answer from.
export enum Recovering
  Done(Recovered)
  Failed(Failure.Problem)
end

## The result of checking: the types, or the first problem.
export enum Checking
  Done(Checked)
  Failed(Failure.Problem)
end

## A program that checked and the result, for a check of the same program after some edits.
export struct Earlier
  linked: Linker.Linked
  checked: Checked
end

## What a check may take from an earlier one: the modules of `clean` are those of the new program that read the same
## texts as in `earlier`, with everything they import (analysis/cache.agc finds them). The checker takes the entries
## of those that `earlier.linked` has with the same ids, and does not check them again.
export struct Reusing
  earlier: Earlier
  clean: Set[String]
end

## The result of `check_query_reusing` and the number of modules it did not check again: those of `Reusing.clean` that
## the earlier program also has with the same ids and constants (the others are checked, so this may be less).
export struct Rechecked
  checking: Checking
  taken: Int
end

## Checks a linked program. The settings tell where the files of the prelude are read.
export def check(linked: Linker.Linked, settings: Env.Settings) -> Checking
  return finished(run(linked, settings, true, false, taking(linked, Ast.Optional.Absent)))
end

## Checks a linked program as `check_query` does, but a function whose body fails to check does not stop the run: its
## problem is kept and the other functions are checked. `checked` holds the types of the functions that passed (those
## of a failed function stay Unknown), so a query can answer about the rest; `problems` are the failures in program
## order, and the first is the one `check_query` gives. A failure of the registration of the declarations, of the main
## rule or of the module constants leaves no part that passes, so it is the failure, as for `check_query`.
export def check_recovering(linked: Linker.Linked, settings: Env.Settings) -> Recovering
  return recovered(run(linked, settings, false, true, taking(linked, Ast.Optional.Absent)))
end

## `check_recovering`, taking from an earlier check what `reusing` says is unchanged. The answer is the one of
## `check_recovering` without it.
export def check_recovering_reusing(linked: Linker.Linked, settings: Env.Settings, reusing: Reusing) -> Recovering
  return recovered(run(linked, settings, false, true, taking(linked, Ast.Optional.Present(reusing))))
end

## Checks a linked program as `check` does, without the rule that it declares a main (CHECK-MAIN): `agentica check` and
## a query about a position (`agentica type-at`) take a library file as well as a program. A main that is declared must
## still be `main() -> Void`, and every other rule holds.
export def check_query(linked: Linker.Linked, settings: Env.Settings) -> Checking
  return finished(run(linked, settings, false, false, taking(linked, Ast.Optional.Absent)))
end

## `check_query`, taking from an earlier check what `reusing` says is unchanged. The answer is the one of `check_query`
## without it, and so is the first problem.
export def check_query_reusing(linked: Linker.Linked, settings: Env.Settings, reusing: Reusing) -> Rechecked
  taken = taking(linked, Ast.Optional.Present(reusing))
  return Rechecked(checking: finished(run(linked, settings, false, false, taken)), taken: taken.clean.size)
end

## Checks a linked program as `check_query` does, except that the modules of `clean` are not checked: not their
## function bodies, constants or field defaults. The type of each of their constants is in `constants`, by linked name,
## as a module that was checked leaves it (analysis/front.agc takes both from the cache of checked modules, modules/
## check_cache.agc, which vouches for them). The first problem is the one `check_query` gives; the types of the nodes
## of a clean module are not known (Unknown).
export def check_query_taking(
  linked: Linker.Linked,
  settings: Env.Settings,
  clean: Set[String],
  constants: Map[String, T.Type],
) -> Checking
  st = State.fresh().with(types: State.no_types(ids_of(linked)))
  return finished(run(linked, settings, false, false, Reuse.Taken(st: st, constants: constants, clean: clean)))
end

def recovered(result: Result[Recovered]) -> Recovering
  if result.ok?
    return Recovering.Done(result.unwrap!)
  end

  return Recovering.Failed(Failure.unpack(result.message))
end

def finished(result: Result[Recovered]) -> Checking
  if result.ok?
    return Checking.Done(result.unwrap!.checked)
  end

  return Checking.Failed(Failure.unpack(result.message))
end

# The context of the run: the builtin records and enums, the tables built once, and the text of each file.
def start(linked: Linker.Linked) -> State.Cx
  texts: Map[String, String] = {}
  for module in linked.modules
    texts = texts.put(module.file, module.text)
  end

  return State.Cx(
    help: Help.tables(),
    structs: RECORDS,
    struct_params: {},
    field_defaults: {},
    enums: ENUMS,
    aliases: {},
    resources: Set.new([]),
    c_structs: Set.new([]),
    functions: {},
    constants: {},
    type_params: [],
    file: linked.modules[0].file,
    texts: texts,
    expression: &Expr.check_expression,
    prelude: false,
  )
end

# `recover` keeps the problem of a function body and goes on with the next function; without it the first problem ends
# the run.
def run(
  linked: Linker.Linked,
  settings: Env.Settings,
  main_required: Bool,
  recover: Bool,
  taken: Reuse.Taken,
) -> Result[Recovered]
  base = start(linked)
  cx = try Register.register(base, linked.modules)
  try Register.check_main(cx, linked.modules, linked.roots, linked.root.span, main_required)
  cx = cx.with(constants: taken.constants)
  done = try Constants.check_all(cx, taken.st, linked.modules, taken.clean)
  cx = done.cx
  st = done.st
  # Like a constant, the default of a field belongs to no function, so a failure of one is the failure of the run.
  for module in linked.modules
    if taken.clean.include?(module.key)
      next
    end

    for decl in module.declarations
      case decl
        Ast.Decl.Struct(node) -> st = try DefaultChecks.check_field_types(cx.with(file: module.file), st, node)
        _ -> st = st
      end
    end
  end

  problems: List[Failure.Problem] = []
  failed: List[String] = []
  for module in linked.modules
    if taken.clean.include?(module.key)
      next
    end

    here = cx.with(file: module.file)
    for decl in module.declarations
      case decl
        Ast.Decl.Function(node) ->
          step = Statements.check_function(here, st, node)
          if step.ok?
            st = step.unwrap!
          elsif recover
            problems = problems.push(Failure.unpack(step.message))
            failed = failed.push(node.name)
          else
            return error(step.message)
          end

        _ -> st = st
      end
    end
  end

  # The prelude functions are attached in the order of the calls in `st.bodies`, and their ids start after the ids of
  # the program. With modules taken from an earlier check that order, and so those ids, can differ from a cold check;
  # no answer reads them, so nothing may rely on them.
  attached = try Prelude.attach(settings, base, st)
  checked = Checked(
    types: attached.st.types,
    resolved: attached.st.resolved,
    constants: done.order,
    constant_types: cx.constants,
    prelude: attached.modules,
    bodies: attached.st.bodies,
    step_tries: attached.st.step_tries,
    bound: attached.st.bound,
  )
  return ok(Recovered(checked: checked, problems: problems, failed: failed))
end

# What the run starts from: nothing, or the entries of the unchanged modules of the earlier check.
def taking(linked: Linker.Linked, reusing: Ast.Optional[Reusing]) -> Reuse.Taken
  case reusing
    Ast.Optional.Present(found) ->
      before = found.earlier
      old = State.fresh().with(
        types: before.checked.types,
        resolved: before.checked.resolved,
        bound: before.checked.bound,
        bodies: before.checked.bodies,
        step_tries: before.checked.step_tries,
      )
      return Reuse.take(linked, before.linked, old, before.checked.constant_types, found.clean)
    Ast.Optional.Absent ->
      st = State.fresh().with(types: State.no_types(ids_of(linked)))
      none: Set[String] = Set.new([])
      return Reuse.Taken(st: st, constants: {}, clean: none)
  end
end

# The number of node ids of the program, with the room the linker took for the receivers of constants (Linked.ids).
def ids_of(linked: Linker.Linked) -> Int
  return linked.ids
end
