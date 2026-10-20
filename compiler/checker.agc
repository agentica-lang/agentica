## The type checker: takes a linked program and gives the type of every expression and the
## resolution of every method call, or the first problem. The declarations are registered first (enums, structs,
## variants, functions, main), then the module constants are ordered and checked, then each function is checked in
## program order, file by file.

import Ast from "ast"
import Constants from "check_const"
import Expr from "check_expr"
import Failure from "check_failure"
import Help from "check_help"
import Register from "check_register"
import State from "check_state"
import Statements from "check_stmt"
import Env from "link_env"
import Linker from "linker"
import Prelude from "prelude"
import T from "types"
import {ENUMS, RECORDS} from "builtins"

## What checking learned: the type of each expression and block, in a list indexed by node id (Unknown for a node that
## has none: node ids are dense, so a list is faster than a Map to write and read), what each method call or field
## access resolved to, by node id (the lowering reads them), and the linked names of the module constants in
## initialization order (the lowering reads that too, and does not order them again). prelude is the files of the
## compiler prelude that the program calls (prelude.agc), checked with it: the lowering adds them to the files of the
## program. bodies is the prelude function each call of a prelude builtin runs, by id of the call. step_tries is the
## id of each `try` in the block of a Lazy method (State.St.step).
export struct Checked
  types: List[T.Type]
  resolved: Map[Int, State.Resolved]
  constants: List[String]
  prelude: List[Linker.LinkedModule]
  bodies: Map[Int, String]
  step_tries: Set[Int]
end

## The result of checking: the types, or the first problem.
export enum Checking
  Done(Checked)
  Failed(Failure.Problem)
end

## Checks a linked program. The settings tell where the files of the prelude are read.
export def check(linked: Linker.Linked, settings: Env.Settings) -> Checking
  result = run(linked, settings)
  if result.ok?
    return Checking.Done(result.unwrap!)
  end
  return Checking.Failed(Failure.unpack(result.message))
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

def run(linked: Linker.Linked, settings: Env.Settings) -> Result[Checked]
  base = start(linked)
  cx = try Register.register(base, linked.modules)
  try Register.check_main(cx, linked.modules, linked.root.span)
  st = State.fresh().with(types: no_types(ids_of(linked), max_repeat()))
  done = try Constants.check_all(cx, st, linked.modules)
  cx = done.cx
  st = done.st
  for module in linked.modules
    here = cx.with(file: module.file)
    for decl in module.declarations
      case decl
        Ast.Decl.Function(node) -> st = try Statements.check_function(here, st, node)
        _ -> st = st
      end
    end
  end
  attached = try Prelude.attach(settings, base, st)
  return ok(
    Checked(
      types: attached.st.types,
      resolved: attached.st.resolved,
      constants: done.order,
      prelude: attached.modules,
      bodies: attached.st.bodies,
      step_tries: attached.st.step_tries,
    ),
  )
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
