## Statements, blocks, case and functions. Expressions are checked through State.expr, because they are in a module
## that imports this one.

import Ast from "../syntax/ast"
import Model from "../catalog/builtin_model"
import DefaultChecks from "check_defaults"
import Flow from "check_flow"
import State from "check_state"
import Types from "check_types"
import Unused from "check_unused"
import Source from "../syntax/source"
import T from "../syntax/types"

## What the arms of a case have covered so far: the variants named, the literals seen, and whether a wildcard arm came.
struct Arms
  covered: List[String]
  literals: List[Ast.LitValue]
  wildcard: Bool
end

# The arm after checking: the state and what the arms cover now.
struct ArmDone
  st: State.St
  arms: Arms
end

## Checks a function: its body with the parameters in scope, then that every path returns a value when the result is
## not Void.
export def check_function(cx: State.Cx, st: State.St, node: Ast.FunctionDecl) -> Result[State.St]
  signature = cx.functions[node.name]
  here = st.with(loops: 0, result: State.Slot.Known(signature.result), signature: signature_text(node, signature))
  checked = try DefaultChecks.check_types(cx, here, node, signature.params)
  inner = State.enter(checked)
  index = 0
  while index < node.params.size
    param = node.params[index]
    inner = try State.introduce(cx, inner, param.name, signature.params[index], param.span, false)
    inner = State.record_bound(inner, param.id, [signature.params[index]])
    index += 1
  end
  inner = try check_block(cx, inner, node.body)
  if !T.is(signature.result, "Void") and !Flow.block_returns?(node.body)
    return error(
      State.fail_maybe(
        cx,
        inner,
        "CHECK-MISSING-RETURN",
        "function \"#{T.display_name(node.name)}\" must return #{T.to_text(signature.result)} on every path",
        node.span,
        Flow.missing_return_help(node.body, T.to_text(signature.result)),
      ),
    )
  end
  return ok(State.leave(inner, here))
end

## Checks the statements in order.
export def check_block(cx: State.Cx, st: State.St, statements: List[Ast.Stmt]) -> Result[State.St]
  current = st
  for statement in statements
    current = try check_statement(cx, current, statement)
  end
  return ok(current)
end

## Checks the body of a block literal (do |x| ... end) against the parameter types and result type its context knows
## (Absent and Unknown when it knows none). A known_result of Result[Unknown] says the block must give a Result whose
## type the body decides (Slot.InferResult). The block's type is Fn(parameters, result), and it is recorded for the
## block's id. each_receiver is the list of a List.each call, for the help of CHECK-CAPTURED-ASSIGNMENT.
export def check_block_body(
  cx: State.Cx,
  st: State.St,
  block: Ast.BlockLit,
  known_params: Ast.Optional[List[T.Type]],
  known_result: T.Type,
  each_receiver: Ast.Optional[Ast.Expr],
) -> Result[State.Out]
  return check_block_in(cx, st, block, known_params, known_result, each_receiver, false)
end

## check_block_body for the block of a Lazy method when step is true: a `try` in it (not in a block nested in it) ends
## the pipeline, whatever the block's result type (State.St.step).
export def check_block_in(
  cx: State.Cx,
  st: State.St,
  block: Ast.BlockLit,
  known_params: Ast.Optional[List[T.Type]],
  known_result: T.Type,
  each_receiver: Ast.Optional[Ast.Expr],
  step: Bool,
) -> Result[State.Out]
  types = try block_parameter_types(cx, st, block, known_params)
  slot = State.Slot.Infer
  if T.is(known_result, "Result") and T.unknown?(T.item(known_result))
    slot = State.Slot.InferResult
  elsif !T.unknown?(known_result)
    slot = State.Slot.Known(known_result)
  end
  inside = st.with(
    loops: 0,
    result: slot,
    step: step,
    capture: Ast.Optional.Present(
      State.Capture(boundary: st.depth, params: block.params, each_receiver: each_receiver),
    ),
  )
  inside = State.enter(inside)
  index = 0
  while index < types.size
    param = block.params[index]
    inside = try State.introduce(cx, inside, param.name, types[index], param.span, false)
    inside = State.record_bound(inside, param.id, [types[index]])
    index += 1
  end
  done = try block_statements(cx, inside, block.body)
  result = block_result(done.st.result, done.type)
  if !T.is(result, "Void") and T.unknown?(done.type) and !Flow.block_returns?(block.body)
    return error(
      State.fail_help(
        cx,
        done.st,
        "CHECK-MISSING-RETURN",
        "this block must give #{T.to_text(result)} on every path",
        block.span,
        "end the block with an expression, or return a value on every path",
      ),
    )
  end
  block_type = T.Type.Fn(types, result)
  after = State.leave(done.st, st).with(result: st.result, capture: st.capture, loops: st.loops, step: st.step)
  return ok(State.Out(st: State.record_type(after, block.id, block_type), type: block_type))
end

# The statement checked; a nesting past the limit is CHECK-TOO-DEEP.
def check_statement(cx: State.Cx, st: State.St, statement: Ast.Stmt) -> Result[State.St]
  if st.nest >= State.nesting_limit()
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-TOO-DEEP",
        "nesting is deeper than #{State.nesting_limit()} levels",
        statement_span(statement),
        "split the code into smaller functions or simpler expressions",
      ),
    )
  end
  done = try statement_inside(cx, st.with(nest: st.nest + 1), statement)
  return ok(done.with(nest: st.nest))
end

def statement_inside(cx: State.Cx, st: State.St, statement: Ast.Stmt) -> Result[State.St]
  case statement
    Ast.Stmt.Binding(node) -> return check_binding(cx, st, node)
    Ast.Stmt.Return(node) -> return check_return(cx, st, node)
    Ast.Stmt.Expression(node) -> return check_expression_statement(cx, st, node)
    Ast.Stmt.If(node) -> return check_if(cx, st, node)
    Ast.Stmt.Case(node) -> return check_case(cx, st, node)
    Ast.Stmt.While(node) -> return check_while(cx, st, node)
    Ast.Stmt.For(node) -> return check_for(cx, st, node)
    Ast.Stmt.Control(node) -> return check_loop_control(cx, st, node)
  end
end

def check_expression_statement(cx: State.Cx, st: State.St, node: Ast.ExprStmt) -> Result[State.St]
  out = try State.expr_completion(cx, st, node.value, T.Type.Unknown)
  try Unused.check_unused_value(cx, out.st, node.value, out.type)
  return ok(out.st)
end

def check_loop_control(cx: State.Cx, st: State.St, node: Ast.LoopControl) -> Result[State.St]
  if st.loops > 0
    return ok(st)
  end
  help = "use it inside while or for; a function cannot break its caller's loop, so return a value and test it there"
  case st.capture
    Ast.Optional.Present(capture) ->
      help = "inside a block, return leaves the block (Ruby's next); a block cannot break its caller's loop"
    Ast.Optional.Absent -> help = help
  end
  return error(
    State.fail_help(cx, st, "CHECK-LOOP-CONTROL", "#{node.kind} is only valid inside while or for", node.span, help),
  )
end

def check_binding(cx: State.Cx, st: State.St, node: Ast.Binding) -> Result[State.St]
  try State.reserve_local(cx, st, node.name, node.span)
  if node.name == "_"
    out = try State.expr(cx, st, node.value, T.Type.Unknown)
    return ok(out.st)
  end
  declared = T.Type.Unknown
  case node.type
    Ast.Optional.Present(annotation) -> declared = try Types.resolve_type(cx, st, annotation, false)
    Ast.Optional.Absent -> declared = declared
  end
  existing = State.lookup(st, node.name)
  if existing.ok?
    return check_assignment(cx, st, node, existing.unwrap!)
  end
  out = try State.expr(cx, st, node.value, declared)
  type = declared
  if T.unknown?(declared)
    type = out.type
  end
  introduced = try State.introduce(cx, out.st, node.name, type, node.span, false)
  return ok(State.record_bound(introduced, node.id, [type]))
end

# A binding of a name that is already in scope is an assignment: not from inside a block, not with an annotation, not
# to a for variable.
def check_assignment(cx: State.Cx, st: State.St, node: Ast.Binding, existing: State.Binding) -> Result[State.St]
  case st.capture
    Ast.Optional.Present(capture) ->
      if existing.level <= capture.boundary
        return error(
          State.fail_help(
            cx,
            st,
            "CHECK-CAPTURED-ASSIGNMENT",
            "a block cannot assign to \"#{node.name}\", which belongs to the enclosing code",
            node.span,
            Flow.captured_help(node.name, capture),
          ),
        )
      end
    Ast.Optional.Absent -> existing = existing
  end
  case node.type
    Ast.Optional.Present(annotation) -> return error(
      State.fail(
        cx,
        st,
        "CHECK-ANNOTATION-ON-EXISTING",
        "an annotation is only allowed when \"#{node.name}\" is introduced",
        node.span,
      ),
    )
    Ast.Optional.Absent -> existing = existing
  end
  if existing.immutable
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-IMMUTABLE-ASSIGNMENT",
        "\"#{node.name}\" cannot be assigned",
        node.span,
        "\"for\" variables cannot be assigned; copy the value to a new name",
      ),
    )
  end
  out = try State.expr(cx, st, node.value, existing.type)
  return ok(out.st)
end

def check_return(cx: State.Cx, st: State.St, node: Ast.Return) -> Result[State.St]
  case st.result
    State.Slot.Infer -> return return_inferred(cx, st, node)
    State.Slot.InferResult -> return return_inferred_result(cx, st, node)
    State.Slot.Known(expected) -> return return_known(cx, st, node, expected)
  end
end

# A return in a block whose result is not known yet gives it.
def return_inferred(cx: State.Cx, st: State.St, node: Ast.Return) -> Result[State.St]
  case node.value
    Ast.Optional.Present(value) ->
      out = try State.expr_completion(cx, st, value, T.Type.Unknown)
      return ok(out.st.with(result: State.Slot.Known(out.type)))
    Ast.Optional.Absent -> return ok(st.with(result: State.Slot.Known(T.Type.Void)))
  end
end

# A return in a block that must give a Result of a type not known yet: the value must be a Result and gives the type.
def return_inferred_result(cx: State.Cx, st: State.St, node: Ast.Return) -> Result[State.St]
  case node.value
    Ast.Optional.Present(value) ->
      out = try State.expr_completion(cx, st, value, T.Type.Unknown)
      try require_result(cx, out.st, out.type, Ast.expr_span(value))
      return ok(out.st.with(result: State.Slot.Known(out.type)))
    Ast.Optional.Absent ->
      return error(State.mismatch(cx, st, T.Type.Result(T.Type.Var("T")), T.Type.Void, node.span))
  end
end

# CHECK-TYPE-MISMATCH, with the help that shows ok(...), unless the type is a Result.
def require_result(cx: State.Cx, st: State.St, type: T.Type, span: Source.Span) -> Result[Bool]
  if !T.is(type, "Result")
    return error(State.mismatch(cx, st, T.Type.Result(T.Type.Var("T")), type, span))
  end
  return ok(true)
end

def return_known(cx: State.Cx, st: State.St, node: Ast.Return, expected: T.Type) -> Result[State.St]
  case node.value
    Ast.Optional.Present(value) ->
      out = try State.expr_completion_if(cx, st, value, expected, T.is(expected, "Void"))
      return ok(out.st)
    Ast.Optional.Absent ->
      try State.ensure(cx, st, T.Type.Void, expected, node.span)
      return ok(st)
  end
end

def check_if(cx: State.Cx, st: State.St, node: Ast.IfStmt) -> Result[State.St]
  current = st
  for branch in node.branches
    condition = try State.expr(cx, current, branch.condition, T.Type.Bool)
    inner = try check_block(cx, State.enter(condition.st), branch.body)
    current = State.leave(inner, condition.st)
  end
  case node.else_body
    Ast.Optional.Present(body) ->
      inner = try check_block(cx, State.enter(current), body)
      current = State.leave(inner, current)
    Ast.Optional.Absent -> current = current
  end
  return ok(current)
end

def check_while(cx: State.Cx, st: State.St, node: Ast.WhileStmt) -> Result[State.St]
  condition = try State.expr(cx, st, node.condition, T.Type.Bool)
  inner = try in_loop(cx, State.enter(condition.st), node.body)
  return ok(State.leave(inner, condition.st))
end

def check_for(cx: State.Cx, st: State.St, node: Ast.ForStmt) -> Result[State.St]
  iterable = try State.expr(cx, st, node.iterable, T.Type.Unknown)
  type = iterable.type
  if !T.is(type, "List") and !T.is(type, "Set") and !T.is(type, "Range")
    return error(
      State.fail(
        cx,
        iterable.st,
        "CHECK-NOT-A-LIST",
        "\"for\" iterates over a list, a set or a range, found #{T.to_text(type)}",
        node.span,
      ),
    )
  end
  element = T.Type.Int
  if !T.is(type, "Range")
    element = T.item(type)
  end
  inner = try State.introduce(cx, State.enter(iterable.st), node.variable, element, node.span, true)
  inner = State.record_bound(inner, node.id, [element])
  inner = try in_loop(cx, inner, node.body)
  return ok(State.leave(inner, iterable.st))
end

def in_loop(cx: State.Cx, st: State.St, body: List[Ast.Stmt]) -> Result[State.St]
  done = try check_block(cx, st.with(loops: st.loops + 1), body)
  return ok(done.with(loops: st.loops))
end

def check_case(cx: State.Cx, st: State.St, node: Ast.CaseStmt) -> Result[State.St]
  value = try State.expr(cx, st, node.value, T.Type.Unknown)
  value_type = value.type
  names = variant_names(cx, value_type)
  current = value.st
  arms = Arms(covered: [], literals: [], wildcard: false)
  for arm in node.arms
    if arms.wildcard or (names.ok? and all_covered?(names.unwrap!, arms.covered))
      return error(State.fail(cx, current, "CHECK-UNREACHABLE-CASE-ARM", "case arm is unreachable", arm.span))
    end
    checked = try check_arm(cx, current, arm, value_type, arms)
    current = checked.st
    arms = checked.arms
  end
  if !arms.wildcard
    try check_exhaustive(cx, current, node, value_type, names, arms)
  end
  return ok(current)
end

# A guarded arm covers nothing: it may fail at run time, so it adds no variant, no literal and no catch-all to `arms`.
def check_arm(cx: State.Cx, st: State.St, arm: Ast.CaseArm, value_type: T.Type, arms: Arms) -> Result[ArmDone]
  case arm.pattern
    Ast.Pattern.Wildcard(pattern) ->
      body = try arm_body(cx, st, arm)
      return ok(ArmDone(st: body, arms: arms.with(wildcard: arms.wildcard or !guarded?(arm))))
    Ast.Pattern.Literal(pattern) -> return check_literal_arm(cx, st, arm, pattern, value_type, arms)
    Ast.Pattern.Variant(pattern) -> return check_variant_arm(cx, st, arm, pattern, value_type, arms)
  end
end

def check_literal_arm(
  cx: State.Cx,
  st: State.St,
  arm: Ast.CaseArm,
  pattern: Ast.LiteralPattern,
  value_type: T.Type,
  arms: Arms,
) -> Result[ArmDone]
  try check_literal(cx, st, pattern, value_type)
  if arms.literals.any? do |seen: Ast.LitValue| same_literal(seen, pattern.value) end
    return error(State.fail(cx, st, "CHECK-UNREACHABLE-CASE-ARM", "duplicate literal case arm", arm.span))
  end
  body = try arm_body(cx, st, arm)
  if guarded?(arm)
    return ok(ArmDone(st: body, arms: arms))
  end
  return ok(ArmDone(st: body, arms: arms.with(literals: arms.literals.push(pattern.value))))
end

# A literal pattern needs a primitive value of its own type (CHECK-PATTERN-TYPE), at the top of an arm or nested.
def check_literal(cx: State.Cx, st: State.St, pattern: Ast.LiteralPattern, value_type: T.Type) -> Result[Bool]
  pattern_type = literal_type(pattern.value)
  if !Types.primitive?(value_type) or !T.same(value_type, pattern_type)
    return error(
      State.fail(
        cx,
        st,
        "CHECK-PATTERN-TYPE",
        "literal pattern has type #{T.to_text(pattern_type)}, but case value has type #{T.to_text(value_type)}",
        pattern.span,
      ),
    )
  end
  return ok(true)
end

def check_variant_arm(
  cx: State.Cx,
  st: State.St,
  arm: Ast.CaseArm,
  pattern: Ast.VariantPattern,
  value_type: T.Type,
  arms: Arms,
) -> Result[ArmDone]
  payload = payload_types(cx, pattern, value_type)
  if !payload.ok?
    return error(variant_mismatch(cx, st, pattern, value_type))
  end
  if arms.covered.any? do |name: String| name == pattern.variant_name end
    return error(State.fail(cx, st, "CHECK-UNREACHABLE-CASE-ARM", "duplicate enum variant arm", arm.span))
  end
  types = payload.unwrap!
  bound = try bind_pattern(cx, State.enter(st), pattern, types)
  body = try check_arm_body(cx, bound, arm)
  # Only an arm that cannot fail covers its variant: no guard, and nothing but names and _ in the payload.
  if guarded?(arm) or !irrefutable?(pattern)
    return ok(ArmDone(st: State.leave(body, st), arms: arms))
  end
  return ok(ArmDone(st: State.leave(body, st), arms: arms.with(covered: arms.covered.push(pattern.variant_name))))
end

def guarded?(arm: Ast.CaseArm) -> Bool
  case arm.guard
    Ast.Optional.Present(condition) -> return true
    Ast.Optional.Absent -> return false
  end
end

# A pattern with no literal and no variant in its payload matches every value of its variant.
def irrefutable?(pattern: Ast.VariantPattern) -> Bool
  return pattern.slots.all? do |slot: Ast.Slot| !nested?(slot) end
end

def nested?(slot: Ast.Slot) -> Bool
  case slot
    Ast.Slot.Nested(inner) -> return true
    _ -> return false
  end
end

# Checks the slots of a variant pattern against the payload types and introduces the names in the scope of the arm; a
# Void payload must be discarded with _. A nested pattern is checked against the type of its position.
def bind_pattern(cx: State.Cx, st: State.St, pattern: Ast.VariantPattern, types: List[T.Type]) -> Result[State.St]
  if pattern.slots.size != types.size
    return error(
      State.fail(
        cx,
        st,
        "CHECK-ARITY",
        "variant pattern expects #{types.size} binding(s), found #{pattern.slots.size}",
        pattern.span,
      ),
    )
  end
  current = State.record_bound(st, pattern.id, types)
  index = 0
  while index < types.size
    case pattern.slots[index]
      Ast.Slot.Bind(name, _) ->
        if T.is(types[index], "Void")
          return error(
            State.fail(cx, current, "CHECK-VOID-TYPE", "a Void payload must be discarded with _", pattern.span),
          )
        end
        current = try State.introduce(cx, current, name, types[index], pattern.span, false)
      Ast.Slot.Skip -> current = current
      Ast.Slot.Nested(inner) -> current = try check_nested(cx, current, inner, types[index])
    end
    index += 1
  end
  return ok(current)
end

# A pattern in a payload position of the given type: a literal of that type, or a variant of the enum it has.
def check_nested(cx: State.Cx, st: State.St, inner: Ast.Pattern, type: T.Type) -> Result[State.St]
  case inner
    Ast.Pattern.Literal(pattern) ->
      try check_literal(cx, st, pattern, type)
      return ok(st)
    Ast.Pattern.Variant(pattern) ->
      payload = payload_types(cx, pattern, type)
      if !payload.ok?
        return error(variant_mismatch(cx, st, pattern, type))
      end
      return bind_pattern(cx, st, pattern, payload.unwrap!)
    Ast.Pattern.Wildcard(pattern) -> return ok(st)
  end
end

# The guard, a Bool that may read the names of the pattern, then the body, in the scope of the arm that `bound` opened.
def check_arm_body(cx: State.Cx, bound: State.St, arm: Ast.CaseArm) -> Result[State.St]
  current = bound
  case arm.guard
    Ast.Optional.Present(condition) ->
      checked = try State.expr(cx, bound, condition, T.Type.Bool)
      current = checked.st
    Ast.Optional.Absent -> current = bound
  end
  return check_block(cx, current, arm.body)
end

def arm_body(cx: State.Cx, st: State.St, arm: Ast.CaseArm) -> Result[State.St]
  inner = try check_arm_body(cx, State.enter(st), arm)
  return ok(State.leave(inner, st))
end

# The payload types of a variant pattern: Ok and Err of a Result, or the variant of the enum the value has, with its
# type arguments filled in. An error when the pattern names another enum or no such variant.
def payload_types(cx: State.Cx, pattern: Ast.VariantPattern, value_type: T.Type) -> Result[List[T.Type]]
  case value_type
    T.Type.Result(item) if pattern.enum_name == "Result" and pattern.variant_name == "Ok" -> return ok([item])
    T.Type.Result(_) if pattern.enum_name == "Result" and pattern.variant_name == "Err" -> return ok([T.Type.String])
    T.Type.Enum(name, args) if pattern.enum_name == name ->
      definition = cx.enums.get(name)
      if definition.ok?
        return variant_payload(definition.unwrap!, pattern.variant_name, args)
      end
    _ -> return error("no such variant")
  end
  return error("no such variant")
end

def variant_payload(definition: Model.EnumDef, variant_name: String, args: List[T.Type]) -> Result[List[T.Type]]
  substitutions: Map[String, T.Type] = {}
  index = 0
  while index < definition.parameters.size and index < args.size
    substitutions = substitutions.put(definition.parameters[index], args[index])
    index += 1
  end
  for variant in definition.variants
    if variant.name == variant_name
      return ok(Types.substitute_all(variant.payload, substitutions))
    end
  end
  return error("no such variant")
end

def variant_mismatch(cx: State.Cx, st: State.St, pattern: Ast.VariantPattern, value_type: T.Type) -> String
  if cx.aliases.has_key?(pattern.enum_name)
    target = Types.alias_target_text(cx, st, pattern.enum_name)
    if target.ok?
      variant = "#{T.display_name(pattern.enum_name)}.#{pattern.variant_name}"
      underlying = "#{target.unwrap!}.#{pattern.variant_name}"
      return State.fail_help(
        cx,
        st,
        "CHECK-PATTERN-TYPE",
        "variant pattern \"#{variant}\" does not match #{T.to_text(value_type)}",
        pattern.span,
        "#{variant} names #{underlying}; match the underlying enum variant instead",
      )
    end
  end
  if T.is(value_type, "Enum") and pattern.enum_name == T.name(value_type)
    return State.fail(
      cx,
      st,
      "CHECK-UNKNOWN-VARIANT",
      "enum \"#{T.display_name(pattern.enum_name)}\" has no variant \"#{pattern.variant_name}\"",
      pattern.span,
    )
  end
  variant = "#{T.display_name(pattern.enum_name)}.#{pattern.variant_name}"
  return State.fail(
    cx,
    st,
    "CHECK-PATTERN-TYPE",
    "variant pattern \"#{variant}\" does not match #{T.to_text(value_type)}",
    pattern.span,
  )
end

# The variant names a case on this type must cover: Ok and Err for a Result, the variants of an enum; an error for any
# other type.
def variant_names(cx: State.Cx, value_type: T.Type) -> Result[List[String]]
  if T.is(value_type, "Result")
    return ok(["Ok", "Err"])
  elsif T.is(value_type, "Enum")
    definition = cx.enums.get(T.name(value_type))
    if definition.ok?
      return ok(definition.unwrap!.variants.map do |variant: Model.Variant| variant.name end)
    end
  end
  return error("not an enum")
end

def all_covered?(names: List[String], covered: List[String]) -> Bool
  return names.all? do |name: String| covered.any? do |seen: String| seen == name end end
end

def check_exhaustive(
  cx: State.Cx,
  st: State.St,
  node: Ast.CaseStmt,
  value_type: T.Type,
  names: Result[List[String]],
  arms: Arms,
) -> Result[Bool]
  if !names.ok?
    return error(
      State.fail(cx, st, "CHECK-NON-EXHAUSTIVE-CASE", "case on a non-enum value requires a final _ arm", node.span),
    )
  end
  if !all_covered?(names.unwrap!, arms.covered)
    return error(
      State.fail(
        cx,
        st,
        "CHECK-NON-EXHAUSTIVE-CASE",
        "case must cover every variant of #{T.to_text(value_type)} or include _",
        node.span,
      ),
    )
  end
  return ok(true)
end

# The type of a literal.
def literal_type(value: Ast.LitValue) -> T.Type
  case value
    Ast.LitValue.Whole(number) -> return T.Type.Int
    Ast.LitValue.Huge(digits) -> return T.Type.Int
    Ast.LitValue.Real(number) -> return T.Type.Float
    Ast.LitValue.Text(text) -> return T.Type.String
    Ast.LitValue.Flag(flag) -> return T.Type.Bool
    Ast.LitValue.Nothing -> return T.Type.Nil
  end
end

# equal? on literals: a float matches on its bits, so 0.0 and -0.0 differ.
def same_literal(a: Ast.LitValue, b: Ast.LitValue) -> Bool
  case a
    Ast.LitValue.Whole(x) -> return whole_is?(b, x)
    Ast.LitValue.Huge(x) -> return huge_is?(b, x)
    Ast.LitValue.Real(x) -> return real_is?(b, x)
    Ast.LitValue.Text(x) -> return text_is?(b, x)
    Ast.LitValue.Flag(x) -> return flag_is?(b, x)
    Ast.LitValue.Nothing -> return nothing?(b)
  end
end

def whole_is?(b: Ast.LitValue, x: Int) -> Bool
  case b
    Ast.LitValue.Whole(y) -> return x == y
    _ -> return false
  end
end

def huge_is?(b: Ast.LitValue, x: String) -> Bool
  case b
    Ast.LitValue.Huge(y) -> return x == y
    _ -> return false
  end
end

def real_is?(b: Ast.LitValue, x: Float) -> Bool
  case b
    Ast.LitValue.Real(y) -> return Float.to_bits(x) == Float.to_bits(y)
    _ -> return false
  end
end

def text_is?(b: Ast.LitValue, x: String) -> Bool
  case b
    Ast.LitValue.Text(y) -> return x == y
    _ -> return false
  end
end

def flag_is?(b: Ast.LitValue, x: Bool) -> Bool
  case b
    Ast.LitValue.Flag(y) -> return x == y
    _ -> return false
  end
end

def nothing?(b: Ast.LitValue) -> Bool
  case b
    Ast.LitValue.Nothing -> return true
    _ -> return false
  end
end

def block_parameter_types(
  cx: State.Cx,
  st: State.St,
  block: Ast.BlockLit,
  known: Ast.Optional[List[T.Type]],
) -> Result[List[T.Type]]
  case known
    Ast.Optional.Present(types) ->
      if types.size != block.params.size
        return error(
          State.fail(
            cx,
            st,
            "CHECK-ARITY",
            "this block takes #{types.size} parameter(s), found #{block.params.size}",
            block.span,
          ),
        )
      end
    Ast.Optional.Absent -> known = known
  end
  out: List[T.Type] = []
  index = 0
  while index < block.params.size
    out = out.push(try block_parameter_type(cx, st, block.params[index], known, index))
    index += 1
  end
  return ok(out)
end

# The type of one block parameter: the annotation and the context agree, or one of them gives it.
def block_parameter_type(
  cx: State.Cx,
  st: State.St,
  param: Ast.BlockParam,
  known: Ast.Optional[List[T.Type]],
  index: Int,
) -> Result[T.Type]
  annotated = T.Type.Unknown
  case param.type
    Ast.Optional.Present(annotation) -> annotated = try Types.resolve_type(cx, st, annotation, false)
    Ast.Optional.Absent -> annotated = annotated
  end
  context = T.Type.Unknown
  case known
    Ast.Optional.Present(types) -> context = types[index]
    Ast.Optional.Absent -> context = context
  end
  if !T.unknown?(annotated) and !T.unknown?(context)
    if !T.same(annotated, context)
      return error(State.mismatch(cx, st, context, annotated, param.span))
    end
    return ok(context)
  elsif !T.unknown?(annotated)
    return ok(annotated)
  elsif !T.unknown?(context)
    return ok(context)
  end
  return error(
    State.fail_help(
      cx,
      st,
      "CHECK-BLOCK-TYPE",
      "the type of block parameter \"#{param.name}\" is not known here",
      param.span,
      "annotate it, as in do |#{param.name}: Int| ... end",
    ),
  )
end

# The statements of a block: all but the last are statements; the last one, an expression, is the value of the block.
# The type in the result is Unknown when the last statement gives no value.
def block_statements(cx: State.Cx, st: State.St, statements: List[Ast.Stmt]) -> Result[State.Out]
  if statements.size == 0
    return ok(State.Out(st: st, type: T.Type.Unknown))
  end
  current = st
  index = 0
  while index < statements.size - 1
    current = try check_statement(cx, current, statements[index])
    index += 1
  end
  final = statements[statements.size - 1]
  case final
    Ast.Stmt.Expression(node) -> return final_expression(cx, current, node.value)
    _ ->
      done = try check_statement(cx, current, final)
      return ok(State.Out(st: done, type: T.Type.Unknown))
  end
end

def final_expression(cx: State.Cx, st: State.St, value: Ast.Expr) -> Result[State.Out]
  case st.result
    State.Slot.Infer -> return State.expr_completion(cx, st, value, T.Type.Unknown)
    State.Slot.InferResult -> return final_inferred_result(cx, st, value)
    State.Slot.Known(expected) -> return final_known(cx, st, value, expected)
  end
end

# The last expression of a block that must give a Result of a type not known yet: a Void value reaches the check, so
# it gets the help that shows ok(...), and a Result gives the type.
def final_inferred_result(cx: State.Cx, st: State.St, value: Ast.Expr) -> Result[State.Out]
  out = try State.expr_completion(cx, st, value, T.Type.Unknown)
  try require_result(cx, out.st, out.type, Ast.expr_span(value))
  return ok(out)
end

def final_known(cx: State.Cx, st: State.St, value: Ast.Expr, expected: T.Type) -> Result[State.Out]
  if T.is(expected, "Void")
    out = try State.expr_completion(cx, st, value, T.Type.Unknown)
    try Unused.check_unused_value(cx, out.st, value, out.type)
    return ok(State.Out(st: out.st, type: T.Type.Unknown))
  end
  return State.expr_completion_if(cx, st, value, expected, T.is(expected, "Result"))
end

# The result type of a block: the one it was given or a return gave, else the type of its last expression, else Void.
def block_result(slot: State.Slot, last: T.Type) -> T.Type
  case slot
    State.Slot.Known(type) -> return type
    State.Slot.Infer -> return infer_result(last)
    State.Slot.InferResult -> return infer_result(last)
  end
end

def infer_result(last: T.Type) -> T.Type
  if T.unknown?(last)
    return T.Type.Void
  end
  return last
end

# The text of a function's signature in the diagnostics: name(param: Type, ...) -> Result.
def signature_text(node: Ast.FunctionDecl, signature: State.Signature) -> String
  parts: List[String] = []
  index = 0
  while index < node.params.size
    parts = parts.push("#{node.params[index].name}: #{T.to_text(signature.params[index])}")
    index += 1
  end
  return "#{T.display_name(node.name)}(#{parts.join(", ")}) -> #{T.to_text(signature.result)}"
end

def statement_span(statement: Ast.Stmt) -> Source.Span
  case statement
    Ast.Stmt.Binding(node) -> return node.span
    Ast.Stmt.Return(node) -> return node.span
    Ast.Stmt.Expression(node) -> return node.span
    Ast.Stmt.If(node) -> return node.span
    Ast.Stmt.While(node) -> return node.span
    Ast.Stmt.For(node) -> return node.span
    Ast.Stmt.Control(node) -> return node.span
    Ast.Stmt.Case(node) -> return node.span
  end
end
