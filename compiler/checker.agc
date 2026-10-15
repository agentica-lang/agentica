## The type checker (src/checker.rkt, `check`): takes a linked program and gives the type of every expression and the resolution of every method call, or the first problem. The declarations are registered first (enums, structs, variants, functions, main), then each function is checked in program order, file by file.

import "ast" as Ast
import "builtins" as Builtins
import "check_expr" as Expr
import "check_failure" as Failure
import "check_help" as Help
import "check_register" as Register
import "check_state" as State
import "check_stmt" as Statements
import "linker" as Linker
import "types" as T

## What checking learned: the type of each expression and block, in a list indexed by node id (Unknown for a node that has none: node ids are dense, so a list is faster than a Map to write and read), and what each method call or field access resolved to, by node id (lower.rkt reads them).
export struct Checked
  types: List[T.Type]
  resolved: Map[Int, State.Resolved]
end

## The result of checking: the types, or the first problem.
export enum Checking
  Done(Checked)
  Failed(Failure.Problem)
end

## Checks a linked program. The catalog is the one the linker used.
export def check(linked: Linker.Linked, catalog: Builtins.Catalog) -> Checking
  result = run(linked, catalog)
  if result.ok?
    return Checking.Done(result.unwrap!)
  end
  return Checking.Failed(Failure.unpack(result.message))
end

# The context of the run: the builtin records and enums, the tables built once, and the text of each file.
def start(linked: Linker.Linked, catalog: Builtins.Catalog) -> State.Cx
  texts: Map[String, String] = {}
  for module in linked.modules
    texts = texts.put(module.file, module.text)
  end
  return State.Cx(catalog: catalog, help: Help.tables(), structs: catalog.records, enums: catalog.enums, functions: {}, type_params: [], file: linked.modules[0].file, texts: texts, expression: &Expr.check_expression)
end

def run(linked: Linker.Linked, catalog: Builtins.Catalog) -> Result[Checked]
  cx = try Register.register(start(linked, catalog), linked.modules)
  try Register.check_main(cx, linked.modules, linked.root.span)
  st = State.fresh().with(types: List.repeat(T.Type.Unknown, ids_of(linked)))
  for module in linked.modules
    here = cx.with(file: module.file)
    for decl in module.declarations
      case decl
        Ast.Decl.Function(node) -> st = try Statements.check_function(here, st, node)
        _ -> st = st
      end
    end
  end
  return ok(Checked(types: st.types, resolved: st.resolved))
end

# The number of node ids of the program: the files are numbered one after the other, so the last one ends it.
def ids_of(linked: Linker.Linked) -> Int
  return linked.modules[linked.modules.size - 1].next_id
end
