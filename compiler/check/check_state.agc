## The state of the checker (a state that is passed and returned, not mutated): what is fixed for the run
## (Cx), what changes while the tree is walked (St), and the small operations on them that every part of the checker
## uses. A check function takes Cx and St and returns the new St with its result (Out for an expression), or fails with
## a packed Problem (diagnostics/problem.agc), so `try` stops at the first diagnostic.

import Model from "../catalog/builtin_model"
import {PUBLIC_NAMES} from "../catalog/builtins"
import Diag from "../diagnostics/diagnostic"
import Failure from "../diagnostics/problem"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import Types from "../syntax/types"
import Help from "check_help"
import Defaults from "defaults"

# List.repeat halts above this count (RUNTIME-INVALID-COUNT), and a program of about 5.7 MB of source has more node
# ids.
MAX_REPEAT = 1_048_576

## A name in scope: its type, whether it cannot be assigned (a for variable), and how many scopes were open when it was
## introduced (a block cannot assign a name from outside it, so the level tells which side a name is on).
export struct Binding
  type: Types.Type
  immutable: Bool
  level: Int
end

## The result type of the function or block being checked. Infer is a block whose result is not known yet: the first
## return or the last expression gives it. InferResult is a block that must give a Result of a type not known yet (the
## block of Task.map): the first return or the last expression gives the whole type, which must be a Result, and
## `try` works in it, since the outer type is a Result whatever the inner one is.
export enum Slot
  Infer
  InferResult
  Known(Types.Type)
end

## The block being checked and the scope depth at its start, for CHECK-CAPTURED-ASSIGNMENT. each_receiver is the list
## of a List.each call, which the help text names.
export struct Capture
  boundary: Int
  params: List[Ast.BlockParam]
  each_receiver: Ast.Optional[Ast.Expr]
end

## What a method call, or a field access that names a method, resolved to: the receiver stays as it is (Self, for to_s
## on a String), it is printed (Text, to_s) or inspected (Inspect), or it is the first argument of the builtin Call.
## Each holds the type of the receiver.
export enum Resolved
  Self(Types.Type)
  Text(Types.Type)
  Inspect(Types.Type)
  Call(String, Types.Type)
end

## The parameter types and the result type of a function, and how many arguments a call takes (Defaults.Shape).
export struct Signature
  params: List[Types.Type]
  result: Types.Type
  shape: Defaults.Shape
end

## What is fixed while the declarations are checked. structs and enums hold the builtin ones and the program's;
## field_defaults the names of the fields that have a default value, by struct; functions the program's; constants the
## type of each module constant by linked name, which grows as the initializers are checked in order. type_params are
## the type parameters in scope (only while the variants of a generic enum are registered). file is the file of the
## declaration being checked, texts the source of every file by name. expression checks an expression: the cycle
## between expressions and statements goes through this field (check_expr.agc puts its own function here), because a
## module cannot import one that imports it. prelude is true while the files of the compiler prelude are checked
## (check_prelude.agc): their type variables are opaque types, and a Map key or Set element may be one.
export struct Cx
  help: Help.Tables
  structs: Map[String, List[Model.Named]]
  field_defaults: Map[String, Set[String]]
  enums: Map[String, Model.EnumDef]
  aliases: Map[String, Ast.TypeAliasDecl]
  resources: Set[String]
  functions: Map[String, Signature]
  constants: Map[String, Types.Type]
  type_params: List[String]
  file: String
  texts: Map[String, String]
  expression: Fn[Cx, St, Ast.Expr, Types.Type, Bool, Result[Out]]
  prelude: Bool
end

## What changes while a function is checked: the type of each node in a list indexed by id (set once the run starts,
## with one slot per node id of the program) and the resolution of the nodes that have one in a Map, the names in
## scope, how many scopes are open, the result type, the loop depth, the block being checked, the nodes of the range
## chain being checked, the signature of the function (for the diagnostics) and the nesting depth (CHECK-TOO-DEEP). The
## names in scope are one persistent Map: a scope is a snapshot of it, so closing a scope puts the snapshot back and
## nothing is ever deleted. bodies is the function of the prelude that each call of a prelude builtin runs, by the id
## of the call (the lowering reads it). step is true inside the block of a Lazy method, where a failed `try` ends the
## pipeline instead of returning from the block, and step_tries holds the id of each such `try` (the lowering emits
## try-step for them). bound holds what each name binding introduced, by the id of its node (see record_bound); it is
## for the queries (`agentica type-at`), and the lowering never reads it.
export struct St
  types: List[Types.Type]
  resolved: Map[Int, Resolved]
  vars: Map[String, Binding]
  depth: Int
  result: Slot
  loops: Int
  capture: Ast.Optional[Capture]
  range_chain: List[Int]
  signature: String
  nest: Int
  bodies: Map[Int, String]
  step: Bool
  step_tries: Set[Int]
  bound: Map[Int, List[Types.Type]]
end

## A call of a builtin that has its own rule: the call, its arguments, the form of the builtin that takes that many
## arguments, and the type the context expects (Unknown when none).
export struct Site
  node: Ast.Call
  args: List[Ast.Expr]
  selected: Model.Builtin
  expected: Types.Type
end

## The result of checking an expression: the new state and the type.
export struct Out
  st: St
  type: Types.Type
end

## The deepest nesting of expressions and statements the checker accepts (CHECK-TOO-DEEP beyond it).
export def nesting_limit() -> Int
  return 1000
end

## A list of `count` slots with no type, built from repeats of at most MAX_REPEAT, so no runtime error escapes for a
## huge program.
export def no_types(count: Int) -> List[Types.Type]
  types: List[Types.Type] = []
  left = count
  while left > 0
    size = MAX_REPEAT
    if left < MAX_REPEAT
      size = left
    end
    types = types.concat(List.repeat(Types.Type.Unknown, size))
    left -= size
  end
  return types
end

## The state at the start of a function: no names, no types.
export def fresh() -> St
  no_tries: Set[Int] = Set.new([])
  return St(
    types: [],
    resolved: {},
    vars: {},
    depth: 0,
    result: Slot.Known(Types.Type.Void),
    loops: 0,
    capture: Ast.Optional.Absent,
    range_chain: [],
    signature: "",
    nest: 0,
    bodies: {},
    step: false,
    step_tries: no_tries,
    bound: {},
  )
end

## The failure of a diagnostic with a help text.
export def fail_help(cx: Cx, st: St, code: String, message: String, span: Source.Span, help: String) -> String
  return Failure.pack(Failure.problem(cx.file, st.signature, code, message, span, Diag.Help.Hint(help)))
end

## The failure of a diagnostic with no help.
export def fail(cx: Cx, st: St, code: String, message: String, span: Source.Span) -> String
  return Failure.pack(Failure.problem(cx.file, st.signature, code, message, span, Diag.Help.NoHelp))
end

## The failure of a diagnostic whose help may be absent ("" is no help).
export def fail_maybe(cx: Cx, st: St, code: String, message: String, span: Source.Span, help: String) -> String
  if help == ""
    return fail(cx, st, code, message, span)
  end
  return fail_help(cx, st, code, message, span, help)
end

## The failure of a diagnostic with the signature of the callee as a note.
export def fail_callee(cx: Cx, st: St, code: String, message: String, span: Source.Span, callee: String) -> String
  base = Failure.problem(cx.file, st.signature, code, message, span, Diag.Help.NoHelp)
  return Failure.pack(base.with(callee: callee))
end

## The failure of a type mismatch: "expected T, found U" with the types as notes and the conversion help.
export def mismatch(cx: Cx, st: St, expected: Types.Type, actual: Types.Type, span: Source.Span) -> String
  base = Failure.problem(
    cx.file,
    st.signature,
    "CHECK-TYPE-MISMATCH",
    "expected #{Types.to_text(expected)}, found #{Types.to_text(actual)}",
    span,
    hint_of(Help.conversion(expected, actual)),
  )
  return Failure.pack(base.with(expected: Types.to_text(expected), actual: Types.to_text(actual)))
end

## actual, or the failure of a mismatch when there is an expected type and it differs.
export def ensure(cx: Cx, st: St, actual: Types.Type, expected: Types.Type, span: Source.Span) -> Result[Types.Type]
  if !Types.unknown?(expected) and !Types.same?(actual, expected)
    return error(mismatch(cx, st, expected, actual, span))
  end
  return ok(actual)
end

## Checks an expression through the hook, where a Void value is an error.
export def expr(cx: Cx, st: St, node: Ast.Expr, expected: Types.Type) -> Result[Out]
  return cx.expression.call(cx, st, node, expected, false)
end

## Checks an expression where a Void value is allowed (a statement, a completion).
export def expr_completion(cx: Cx, st: St, node: Ast.Expr, expected: Types.Type) -> Result[Out]
  return cx.expression.call(cx, st, node, expected, true)
end

## Checks an expression where a Void value is allowed only when completion is true.
export def expr_completion_if(cx: Cx, st: St, node: Ast.Expr, expected: Types.Type, completion: Bool) -> Result[Out]
  return cx.expression.call(cx, st, node, expected, completion)
end

## The state with the type of a node recorded.
export def record_type(st: St, id: Int, type: Types.Type) -> St
  return st.with(types: st.types.set(id, type))
end

## The state with the types that a node introduced as names recorded: one for a parameter, a block parameter, a binding
## or a `for` statement (the type of its variable), and one for each payload position of a variant pattern (the type of
## the name there, if the slot has one). They are kept apart from `types`, which holds expressions only, so a type that
## only a binding names does not reach the lowering.
export def record_bound(st: St, id: Int, types: List[Types.Type]) -> St
  return st.with(bound: st.bound.put(id, types))
end

## The state with the resolution of a node recorded.
export def record_resolved(st: St, id: Int, resolved: Resolved) -> St
  return st.with(resolved: st.resolved.put(id, resolved))
end

## The binding of a name, or an error when the name is not in scope.
export def lookup(st: St, name: String) -> Result[Binding]
  return st.vars.get(name)
end

## Opens a scope: the state to give back to leave when it is closed.
export def enter(st: St) -> St
  return st.with(depth: st.depth + 1)
end

## Closes the scope opened from before: the names, the depth and nothing else go back; types and resolutions stay.
export def leave(st: St, before: St) -> St
  return st.with(vars: before.vars, depth: before.depth)
end

## Introduces a name (a parameter, a binding, a pattern variable, a for variable) in the scope: no builtin constructor
## or function name, and no shadowing. `_` binds nothing: it can repeat and it is never in scope to be read.
export def introduce(cx: Cx, st: St, name: String, type: Types.Type, span: Source.Span, immutable: Bool) -> Result[St]
  if name == "_"
    return ok(st)
  end
  try reserve_local(cx, st, name, span)
  existing = st.vars.get(name)
  if existing.ok?
    if existing.unwrap!.immutable
      return error(
        fail_help(
          cx,
          st,
          "CHECK-SHADOWED-NAME",
          "\"#{name}\" is already visible; Agentica does not allow shadowing",
          span,
          "choose another name",
        ),
      )
    end
    return error(
      fail_help(
        cx,
        st,
        "CHECK-SHADOWED-NAME",
        "\"#{name}\" is already visible; Agentica does not allow shadowing",
        span,
        "assign to it with \"#{name} = value\" instead of introducing it again, or choose another name",
      ),
    )
  end
  return ok(st.with(vars: st.vars.put(name, Binding(type: type, immutable: immutable, level: st.depth))))
end

## CHECK-REDEFINED-NAME for ok and error, which are builtin constructors.
export def reserve_constructor(cx: Cx, st: St, name: String, span: Source.Span) -> Result[Bool]
  if name == "ok" or name == "error"
    return error(fail(cx, st, "CHECK-REDEFINED-NAME", "\"#{name}\" is a builtin constructor", span))
  end
  return ok(true)
end

## CHECK-REDEFINED-NAME for the names a local may not take: ok, error, puts, print, gets and gets!.
export def reserve_local(cx: Cx, st: St, name: String, span: Source.Span) -> Result[Bool]
  try reserve_constructor(cx, st, name, span)
  if name == "puts" or name == "print" or name == "gets" or name == "gets!"
    return error(
      fail_help(
        cx,
        st,
        "CHECK-REDEFINED-NAME",
        "\"#{name}\" is a builtin function",
        span,
        "choose another name, such as line or text",
      ),
    )
  end
  return ok(true)
end

## The names a program may use as a value or a call, for the did-you-mean help: names in scope, functions, public
## builtins.
export def visible_names(cx: Cx, st: St) -> List[String]
  return st.vars.keys.concat(cx.functions.keys).concat(PUBLIC_NAMES)
end

## A Diag.Help for a help text that may be absent ("" is absent).
export def hint_of(text: String) -> Diag.Help
  if text == ""
    return Diag.Help.NoHelp
  end
  return Diag.Help.Hint(text)
end
