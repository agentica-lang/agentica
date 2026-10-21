## The type checker: takes a linked program and gives the type of every expression and the
## resolution of every method call, or the first problem. The declarations are registered first (enums, structs,
## variants, functions, main), then the module constants are ordered and checked, then each function is checked in
## program order, file by file.

import Ast from "../syntax/ast"
import Constants from "check_const"
import Expr from "check_expr"
import Failure from "../diagnostics/problem"
import Help from "check_help"
import Register from "check_register"
import State from "check_state"
import Statements from "check_stmt"
import Env from "../modules/link_env"
import Linker from "../modules/linker"
import Prelude from "prelude_files"
import T from "../syntax/types"
import {ENUMS, RECORDS} from "../catalog/builtins"

## What checking learned: the type of each expression and block, in a list indexed by node id (Unknown for a node that
## has none: node ids are dense, so a list is faster than a Map to write and read), what each method call or field
## access resolved to, by node id (the lowering reads them), and the linked names of the module constants in
## initialization order (the lowering reads that too, and does not order them again). prelude is the files of the
## compiler prelude that the program calls (prelude_files.agc), checked with it: the lowering adds them to the files of
## the program. bodies is the prelude function each call of a prelude builtin runs, by id of the call. step_tries is
## the id of each `try` in the block of a Lazy method (State.St.step). bound is the types that each name binding
## introduced, by node id (State.record_bound), for `agentica type-at`.
export struct Checked
  types: List[T.Type]
  resolved: Map[Int, State.Resolved]
  constants: List[String]
  prelude: List[Linker.LinkedModule]
  bodies: Map[Int, String]
  step_tries: Set[Int]
  bound: Map[Int, List[T.Type]]
end

## What `check_recovering` learned: the types of the functions that passed and the problems of those that did not.
export struct Recovered
  checked: Checked
  problems: List[Failure.Problem]
end

## The result of checking: the types, or the first problem.
export enum Checking
  Done(Checked)
  Failed(Failure.Problem)
end

## Checks a linked program. The settings tell where the files of the prelude are read.
export def check(linked: Linker.Linked, settings: Env.Settings) -> Checking
  return finished(run(linked, settings, true, false))
end

## Checks a linked program as `check_query` does, but a function whose body fails to check does not stop the run: its
## problem is kept and the other functions are checked. `checked` holds the types of the functions that passed (those
## of a failed function stay Unknown), so a query can answer about the rest; `problems` are the failures in program
## order, and the first is the one `check_query` gives. A failure of the registration of the declarations, of the main
## rule or of the module constants leaves no part that passes: `checked` is `unchecked` and `problems` holds that one
## failure.
export def check_recovering(linked: Linker.Linked, settings: Env.Settings) -> Recovered
  result = run(linked, settings, false, true)
  if result.ok?
    return result.unwrap!
  end
  return Recovered(checked: unchecked(linked), problems: [Failure.unpack(result.message)])
end

## The checked data of a program nothing was checked in: every type is Unknown and nothing is resolved or bound.
export def unchecked(linked: Linker.Linked) -> Checked
  return Checked(
    types: no_types(ids_of(linked), max_repeat()),
    resolved: {},
    constants: [],
    prelude: [],
    bodies: {},
    step_tries: Set.new([]),
    bound: {},
  )
end

## Checks a linked program as `check` does, without the rule that it declares a main (CHECK-MAIN): `agentica check` and
## a query about a position (`agentica type-at`) take a library file as well as a program. A main that is declared must
## still be `main() -> Void`, and every other rule holds.
export def check_query(linked: Linker.Linked, settings: Env.Settings) -> Checking
  return finished(run(linked, settings, false, false))
end

## A list of count slots with no type, built from repeats of at most chunk, so no runtime error escapes for a huge
## program.
export def no_types(count: Int, chunk: Int) -> List[T.Type]
  types: List[T.Type] = []
  left = count
  while left > 0
    size = chunk
    if left < chunk
      size = left
    end
    types = types.concat(List.repeat(T.Type.Unknown, size))
    left -= size
  end
  return types
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
    enums: ENUMS,
    aliases: {},
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
def run(linked: Linker.Linked, settings: Env.Settings, main_required: Bool, recover: Bool) -> Result[Recovered]
  base = start(linked)
  cx = try Register.register(base, linked.modules)
  try Register.check_main(cx, linked.modules, linked.root.span, main_required)
  st = State.fresh().with(types: no_types(ids_of(linked), max_repeat()))
  done = try Constants.check_all(cx, st, linked.modules)
  cx = done.cx
  st = done.st
  problems: List[Failure.Problem] = []
  for module in linked.modules
    here = cx.with(file: module.file)
    for decl in module.declarations
      case decl
        Ast.Decl.Function(node) ->
          step = Statements.check_function(here, st, node)
          if step.ok?
            st = step.unwrap!
          elsif recover
            problems = problems.push(Failure.unpack(step.message))
          else
            return error(step.message)
          end
        _ -> st = st
      end
    end
  end
  attached = try Prelude.attach(settings, base, st)
  checked = Checked(
    types: attached.st.types,
    resolved: attached.st.resolved,
    constants: done.order,
    prelude: attached.modules,
    bodies: attached.st.bodies,
    step_tries: attached.st.step_tries,
    bound: attached.st.bound,
  )
  return ok(Recovered(checked: checked, problems: problems))
end

# The number of node ids of the program, with the room the linker took for the receivers of constants (Linked.ids).
def ids_of(linked: Linker.Linked) -> Int
  return linked.ids
end

# List.repeat halts above this count (RUNTIME-INVALID-COUNT), and a program of about 5.7 MB of source has more node
# ids.
def max_repeat() -> Int
  return 1048576
end
