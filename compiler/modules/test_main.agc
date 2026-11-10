## The `main` of a test file that has none (issue #983): its top-level `test_*` functions are its tests, and this pass
## adds `def main() -> Void` with `Test.run([Test.test("name", &test_name), ...])`, in source order. It runs on the
## parsed root file before the linker registers its names, so the generated code is linked and checked as written code.
## Whether the file is a test file is the caller's flag (`Env.Settings.test_file`), never its name.

import Diag from "../diagnostics/diagnostic"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import Declarations from "declarations"
import Failure from "link_failure"

# The prefix that makes a function a test.
TEST_PREFIX = "test_"

## The tree of the test file `file` with the `main` that runs its tests, or the same tree when it has no test
## function (a run of a file with neither is CHECK-MAIN later). A file that declares `main` and test functions is
## CHECK-TEST-MAIN, at `main`, before any test function is looked at: with a `main`, a `test_*` function may be a
## helper of the `Test.run` form, and the problem is the mix. Without one, CHECK-TEST-NAME for a function named just
## `test_` and CHECK-TEST-SIGNATURE for one that takes parameters, is generic or does not return `Result[Void]`, which
## must be written so (the check reads the written type: an alias of it is not one). The new nodes take ids from the id
## of the Program on and the Program the next one, so the ids stay in post-order with no gap, and the next file is
## numbered after them.
export def add_main(file: String, program: Ast.Program) -> Result[Ast.Program]
  tests: List[Ast.FunctionDecl] = []
  main: Optional[Ast.FunctionDecl] = none
  for decl in program.declarations
    case Declarations.unwrap(decl)
      Ast.Decl.Function(function) ->
        if !function.native.some?
          if function.name == "main"
            main = some(function)
          elsif function.name.starts_with?(TEST_PREFIX)
            tests = tests.push(function)
          end
        end

      _ -> next
    end
  end

  return ok(program) if tests.size == 0

  try no_main(file, main)
  for test in tests
    try check_test(file, test)
  end

  ok(with_main(program, tests))
end

# CHECK-TEST-MAIN at a `main` of a file with test functions.
def no_main(file: String, main: Optional[Ast.FunctionDecl]) -> Result[Void]
  case main
    some(declared) ->
      error(
        fail(
          file,
          declared.span,
          "CHECK-TEST-MAIN",
          "a test file with test_ functions must not declare main",
          "remove main: agentica test runs the test_ functions",
        ),
      )
    none -> ok()
  end
end

# CHECK-TEST-NAME or CHECK-TEST-SIGNATURE for a test function that cannot be a test.
def check_test(file: String, function: Ast.FunctionDecl) -> Result[Void]
  if function.name == TEST_PREFIX
    return error(
      fail(
        file,
        function.span,
        "CHECK-TEST-NAME",
        "a test function needs a name after test_",
        "name it test_what_it_checks",
      ),
    )
  end

  if function.params.size > 0 or function.type_parameters.size > 0 or !result_void?(function.result)
    return error(
      fail(
        file,
        function.span,
        "CHECK-TEST-SIGNATURE",
        "a test function must take no parameters and return Result[Void]",
        "write def #{function.name}() -> Result[Void]",
      ),
    )
  end

  ok()
end

def result_void?(result: Ast.TypeRef) -> Bool
  return false if result.name != "Result" or result.args.size != 1

  result.args[0].name == "Void" and result.args[0].args.size == 0
end

def fail(file: String, span: Source.Span, code: String, message: String, help: String) -> String
  Failure.fail_at(Failure.Site(file: file, span: span), code, message, Diag.Help.Hint(help))
end

# The program with `main` after its declarations. Each node is numbered after its children and the siblings before it
# (post-order), from the id the Program had: the result type of `main`, then each test's name, function and call, then
# the list, the call of Test.run, its statement and `main`.
def with_main(program: Ast.Program, tests: List[Ast.FunctionDecl]) -> Ast.Program
  span = tests[0].span
  result = Ast.TypeRef(id: program.id, name: "Void", args: [], span: span)
  next_id = program.id + 1
  cases: List[Ast.Expr] = []
  for test in tests
    name = Ast.Expr.Literal(Ast.Literal(id: next_id, value: Ast.LitValue.Text(test_name(test.name)), span: test.span))
    body = Ast.Expr.FunctionRef(Ast.FunctionRef(id: next_id + 1, name: test.name, span: test.span))
    cases = cases.push(Ast.Expr.Call(call(next_id + 2, "Test.test", [name, body], test.span)))
    next_id += 3
  end

  list = Ast.Expr.ListLit(Ast.ListLit(id: next_id, elements: cases, span: span))
  run = Ast.Expr.Call(call(next_id + 1, "Test.run", [list], span))
  statement = Ast.Stmt.Expression(Ast.ExprStmt(id: next_id + 2, value: run, span: span))
  main = Ast.FunctionDecl(
    id: next_id + 3,
    name: "main",
    name_span: span,
    type_parameters: [],
    type_parameter_spans: [],
    params: [],
    result: result,
    body: [statement],
    doc: none,
    native: none,
    span: span,
  )

  program.with(id: next_id + 4, declarations: program.declarations.push(Ast.Decl.Function(main)))
end

def call(id: Int, name: String, args: List[Ast.Expr], span: Source.Span) -> Ast.Call
  Ast.Call(id: id, name: name, args: args, piped: false, parenthesized: true, span: span)
end

# The name a report shows for the test function `name`: the name without `test_`, with each `_` a space.
def test_name(name: String) -> String
  name.slice(TEST_PREFIX.length, name.length - TEST_PREFIX.length).replace("_", " ")
end
