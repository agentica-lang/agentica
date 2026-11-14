## `bodies` (#1159, experimental): the functions of a file with their bodies as a typed tree, for a tool that
## translates them (a prover, an SMT encoder). The checker keeps no tree of its own: it leaves side tables over the
## linked tree, by node id, and this walk reads them. The type of a node is `Checked.types`, the target of a method
## call (and of `data.size`) is `Checked.resolved`, a call by name keeps the name the linker gave it (a builtin's, or a
## function's linked name), `data[i]` runs `Builtins.index_builtin` (as the lowering does), and a binding is new when
## the checker recorded what it introduced in `Checked.bound` (where the result type of a function is too), and the
## type arguments of a generic call are `Checked.type_args`. So no rule of the checker or the lowering is written
## twice here.

import Builtins from "../catalog/builtins"
import State from "../check/check_state"
import Checker from "../check/checker"
import Defaults from "../check/defaults"
import DiagnosticModel from "../diagnostics/diagnostic_model"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import AstWalk from "../syntax/ast_walk"
import Names from "../syntax/prelude_name"
import Source from "../syntax/source"
import Types from "../syntax/types"
import Model from "model"
import Purity from "purity"

## The functions of the root file of `linked` (checked as `checked`) that have a body, in source order. `file` is the
## name the answer gives the file, and `modules` the prefix and the file of each linked module.
def of_program(
  file: String,
  modules: List[Model.BodyModule],
  linked: Linker.Linked,
  checked: Checker.Checked,
) -> Model.Bodies
  root = linked.modules[0]
  exported: Set[Int] = Set.new([])
  written: Map[Int, String] = {}
  for decl in root.parsed.declarations
    case decl
      Ast.Decl.Export(node) ->
        case node.declaration
          Ast.Decl.Function(function) ->
            exported = exported.add(function.id)
            written = written.put(function.id, function.name)
          _ -> next
        end

      Ast.Decl.Function(function) -> written = written.put(function.id, function.name)
      _ -> next
    end
  end

  program = Purity.program(linked, checked)
  known = Purity.unknown()
  functions: List[Model.Body] = []
  roots: List[Ast.FunctionDecl] = []
  for decl in root.declarations
    case decl
      Ast.Decl.Function(node) if node.native.none? ->
        roots = roots.push(node)
        reasoned = Purity.reasons(program, known, node.name)
        known = reasoned.known
        made = body_of(checked, node, written.get(node.id, node.name), exported.include?(node.id))
        functions = functions.push(made.with(file: file, pure: reasoned.reasons.size == 0, impure: reasoned.reasons))
      _ -> next
    end
  end

  Model.Bodies(
    version: BODIES_VERSION,
    file: file,
    modules: modules,
    functions: functions,
    prelude: prelude_bodies(checked, program, known, roots),
  )
end

private

# The version of the shape. The query is experimental: the shape may change between releases with the same number.
BODIES_VERSION = 1

# The source form of each binary operator token; `and` and `or` are written as words in the answer.
OPERATOR_TEXT: Map[String, String] = {
  "plus": "+", "minus": "-", "multiply": "*", "divide": "/", "modulo": "%", "less": "<", "less-equal": "<=",
  "greater": ">", "greater-equal": ">=", "equal": "==", "not-equal": "!=", "and": "and", "or": "or",
}

# The prelude functions that the calls of the root functions `roots` run, and those that their calls run in turn, each
# once, in the order they are first called.
def prelude_bodies(
  checked: Checker.Checked,
  program: Purity.Program,
  known: Purity.Known,
  roots: List[Ast.FunctionDecl],
) -> List[Model.Body]
  decls: Map[String, Ast.FunctionDecl] = {}
  files: Map[String, String] = {}
  for module in checked.prelude
    for decl in module.declarations
      case decl
        Ast.Decl.Function(node) ->
          decls = decls.put(node.name, node)
          files = files.put(node.name, module.file)
        _ -> next
      end
    end
  end

  found: List[Model.Body] = []
  seen: Set[String] = Set.new([])
  queue = roots
  at = 0
  while at < queue.size
    for name in prelude_calls(checked, queue[at])
      if !seen.include?(name) and decls.has_key?(name)
        seen = seen.add(name)
        decl = decls[name]
        reasoned = Purity.reasons(program, known, name)
        known = reasoned.known
        made = body_of(checked, decl, written_name(name), false)
        found = found.push(made.with(file: files[name], pure: reasoned.reasons.size == 0, impure: reasoned.reasons))
        queue = queue.push(decl)
      end
    end

    at += 1
  end

  found
end

# The linked names of the prelude functions that the calls in `node` run, in source order.
def prelude_calls(checked: Checker.Checked, node: Ast.FunctionDecl) -> List[String]
  names: List[String] = []
  work = node.body.map do |stmt: Ast.Stmt| AstWalk.Node.Stmt(stmt) end
  for param in node.params
    case param.default
      some(value) -> work = work.push(AstWalk.Node.Expr(value))
      none -> next
    end
  end

  work = work.reverse
  while work.size > 0
    item = work.last
    work = work.take(work.size - 1).concat(AstWalk.children(item).reverse)
    case item
      AstWalk.Node.Expr(expr) ->
        name = prelude_of(checked, Ast.expr_id(expr))
        if name != "" and call?(expr)
          names = names.push(name)
        end

      AstWalk.Node.Stmt(_) -> next
    end
  end

  names
end

# Whether `expr` is a node that the answer gives as a `call` or a `function`, so that its `prelude` names what it runs.
def call?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Call(_) -> true
    Ast.Expr.MethodCall(_) -> true
    Ast.Expr.FieldAccess(_) -> true
    Ast.Expr.FunctionRef(_) -> true
    _ -> false
  end
end

# The name of a prelude function as its file writes it: the part after the last "::".
def written_name(linked: String) -> String = linked.split("::").last

def body_of(checked: Checker.Checked, node: Ast.FunctionDecl, name: String, exported: Bool) -> Model.Body
  params = node.params.map do |param: Ast.Param|
    default = param.default.map do |value: Ast.Expr| [expression(checked, value)] end
    Model.BodyParam(
      name: param.name,
      type: bound(checked, param.id, 0),
      range: DiagnosticModel.range_of(param.span),
      default: default.unwrap_or([]),
    )
  end

  Model.Body(
    name: name,
    linked: node.name,
    file: "",
    exported: exported,
    range: DiagnosticModel.range_of(node.span),
    name_range: DiagnosticModel.range_of(node.name_span),
    generics: node.type_parameters,
    params: params,
    result: bound(checked, node.result.id, 0),
    body: statements(checked, node.body),
    pure: true,
    impure: [],
  )
end

def statements(checked: Checker.Checked, body: List[Ast.Stmt]) -> List[Model.Node]
  body.map do |stmt: Ast.Stmt| statement(checked, stmt) end
end

# A block runs from its first statement to its last; an empty one is the empty place at the start of `owner`.
def block(checked: Checker.Checked, body: List[Ast.Stmt], owner: Source.Span) -> Model.Node
  children = statements(checked, body)
  span = Source.Span(start: owner.start, stop: owner.start)
  made = leaf("block", Types.Type.Unknown, span).with(children: children)
  if children.size > 0
    made = made.with(range: DiagnosticModel.Region(start: children[0].range.start, stop: children.last.range.stop))
  end

  made
end

def statement(checked: Checker.Checked, stmt: Ast.Stmt) -> Model.Node
  case stmt
    Ast.Stmt.Binding(node) ->
      # The checker records what a binding introduced only when it makes a new local; an update of a visible one has
      # the type of that local, which is its value's.
      made = checked.bound.has_key?(node.id)
      type = type_of(checked, Ast.expr_id(node.value))
      if made
        type = bound(checked, node.id, 0)
      end

      value = expression(checked, node.value)
      kind = "let"
      if node.name == "_"
        kind = "discard"
      end

      leaf(kind, Types.Type.Unknown, node.span).with(
        type: type,
        range: through(node.span, value),
        text: node.name,
        new: made,
        children: [value],
      )
    Ast.Stmt.Return(node) ->
      case node.value
        some(value) ->
          made = expression(checked, value)
          leaf("return", Types.Type.Unknown, node.span).with(
            type: made.type,
            range: through(node.span, made),
            children: [made],
          )
        none -> leaf("return", Types.Type.Unknown, node.span)
      end

    Ast.Stmt.Expression(node) -> expression(checked, node.value)
    Ast.Stmt.If(node) -> if_node(checked, node)
    Ast.Stmt.Case(node) -> case_node(checked, node)
    Ast.Stmt.While(node) ->
      condition = expression(checked, node.condition)
      leaf("while", Types.Type.Unknown, node.span).with(children: [condition, block(checked, node.body, node.span)])
    Ast.Stmt.For(node) ->
      iterable = expression(checked, node.iterable)
      leaf("for", Types.Type.Unknown, node.span).with(
        type: bound(checked, node.id, 0),
        text: node.variable,
        children: [iterable, block(checked, node.body, node.span)],
      )
    Ast.Stmt.Control(node) -> leaf(node.kind, Types.Type.Unknown, node.span)
  end
end

# The children of each branch are [condition, block], for a guard (`return x if c`) too, whose block is its one
# statement, written before the condition: the block then takes the statement's span.
def if_node(checked: Checker.Checked, node: Ast.IfStmt) -> Model.Node
  children = node.branches.map do |branch: Ast.IfBranch|
    owner = branch.span
    if node.guard
      owner = Ast.stmt_span(branch.body[0])
    end

    leaf("branch", Types.Type.Unknown, branch.span).with(
      children: [expression(checked, branch.condition), block(checked, branch.body, owner)],
    )
  end

  case node.else_body
    some(body) -> children = children.push(block(checked, body, node.span))
    none -> children = children
  end

  leaf("if", Types.Type.Unknown, node.span).with(children: children)
end

# A case statement, or a case that gives a value (its type is then the case's own).
def case_node(checked: Checker.Checked, node: Ast.CaseStmt) -> Model.Node
  value = expression(checked, node.value)
  matched = type_of(checked, Ast.expr_id(node.value))
  arms = node.arms.map do |arm: Ast.CaseArm|
    parts = [pattern(checked, arm.pattern, matched)]
    case arm.guard
      some(guard) -> parts = parts.push(guard_node(checked, guard))
      none -> parts = parts
    end

    leaf("arm", Types.Type.Unknown, arm.span).with(children: parts.push(block(checked, arm.body, arm.span)))
  end

  made = leaf("case", Types.Type.Unknown, node.span)
  made.with(type: type_of(checked, node.id), children: [value].concat(arms))
end

def guard_node(checked: Checker.Checked, guard: Ast.Expr) -> Model.Node
  leaf("guard", Types.Type.Bool, Ast.expr_span(guard)).with(children: [expression(checked, guard)])
end

def pattern(checked: Checker.Checked, found: Ast.Pattern, matched: Model.TypeShape) -> Model.Node
  case found
    Ast.Pattern.Wildcard(node) -> leaf("wildcard", Types.Type.Unknown, node.span).with(type: matched)
    Ast.Pattern.Or(node) ->
      children = node.patterns.map do |inner: Ast.Pattern| pattern(checked, inner, matched) end
      leaf("alternatives", Types.Type.Unknown, node.span).with(type: matched, children: children)
    Ast.Pattern.Literal(node) ->
      leaf("literal", Types.Type.Unknown, node.span).with(type: matched, text: literal_text(node.value))
    Ast.Pattern.Variant(node) ->
      payload = checked.bound.get(node.id, [])
      slots: List[Model.Node] = []
      at = 0
      for slot in node.slots
        type = Types.Type.Unknown
        if at < payload.size
          type = payload[at]
        end

        case slot
          Ast.Slot.Bind(name, span) -> slots = slots.push(leaf("bind", type, span).with(text: name))
          Ast.Slot.Skip -> slots = slots.push(leaf("skip", type, node.span))
          Ast.Slot.Nested(inner) -> slots = slots.push(pattern(checked, inner, shape(type)))
        end

        at += 1
      end

      leaf("variant", Types.Type.Unknown, node.span).with(
        type: matched,
        target: variant_target(node.enum_name, node.variant_name),
        children: slots,
      )
  end
end

# A variant of Result or Optional by the word a program writes (`ok`, `error`, `some`, `none`); any other as
# `Enum.Variant` with the linked enum name.
def variant_target(enum_name: String, variant_name: String) -> String
  if enum_name == "Result" and variant_name == "Ok"
    return "ok"
  elsif enum_name == "Result" and variant_name == "Err"
    return "error"
  elsif enum_name == "Optional" and variant_name == "Some"
    return "some"
  elsif enum_name == "Optional" and variant_name == "None"
    return "none"
  end

  "#{enum_name}.#{variant_name}"
end

def expression(checked: Checker.Checked, expr: Ast.Expr) -> Model.Node
  id = Ast.expr_id(expr)
  span = Ast.expr_span(expr)
  type = types_at(checked, id)
  case expr
    Ast.Expr.Literal(node) -> leaf(literal_kind(node.value), type, span).with(text: literal_text(node.value))
    Ast.Expr.Name(node) -> leaf("local", type, span).with(text: node.name)
    Ast.Expr.Call(node) ->
      # The values of the named arguments of error(...) follow the positional ones.
      given = Defaults.arguments(node.args, node.named)
      call_leaf(checked, id, type, span, node.name).with(children: bound_arguments(checked, id, given, span))
    Ast.Expr.MethodCall(node) ->
      case checked.resolved.get(id)
        some(State.Resolved.Call(name, _)) ->
          given = [node.target].concat(Defaults.arguments(node.args, node.named))
          call_leaf(checked, id, type, span, name).with(children: bound_arguments(checked, id, given, span))
        _ ->
          # A call of a function held in a field (`h.run(x)`), or a method every type has (`to_s`, `inspect`).
          kind = "method"
          if checked.resolved.get(id) == some(State.Resolved.FieldCall)
            kind = "invoke"
          end

          leaf(kind, type, span).with(
            text: node.name,
            children: arguments(checked, [node.target].concat(Defaults.arguments(node.args, node.named))),
          )
      end

    Ast.Expr.FieldAccess(node) ->
      case checked.resolved.get(id)
        some(State.Resolved.Call(name, _)) ->
          call_leaf(checked, id, type, span, name).with(children: [expression(checked, node.target)])
        some(_) -> leaf("method", type, span).with(text: node.name, children: [expression(checked, node.target)])
        none -> leaf("field", type, span).with(text: node.name, children: [expression(checked, node.target)])
      end

    Ast.Expr.Index(node) ->
      children = [expression(checked, node.target), expression(checked, node.index)]
      builtin = Builtins.index_builtin(types_at(checked, Ast.expr_id(node.target)))
      return leaf("call", type, span).with(target: builtin, children: children) if builtin != ""

      leaf("index", type, span).with(children: children)
    Ast.Expr.Try(node) -> leaf("try", type, span).with(children: [expression(checked, node.operand)])
    Ast.Expr.Unary(node) ->
      operand = expression(checked, node.operand)
      return leaf("not", type, span).with(text: "!", children: [operand]) if node.op == "not"

      # -9223372036854775808 only fits under its minus: it is one literal.
      huge = huge_digits(node.operand)
      return leaf("int", type, span).with(text: "-#{huge}") if huge != ""

      leaf("neg", type, span).with(text: "-", children: [operand])
    Ast.Expr.Binary(node) ->
      if node.op == "dot-dot" or node.op == "dot-dot-dot"
        text = ".."
        if node.op == "dot-dot-dot"
          text = "..."
        end

        return leaf("range", type, span).with(
          text: text,
          children: [expression(checked, node.left), expression(checked, node.right)],
        )
      end

      kind = "op"
      if node.op == "and" or node.op == "or"
        kind = node.op
      end

      leaf(kind, type, span).with(
        text: OPERATOR_TEXT.get(node.op, node.op),
        children: [expression(checked, node.left), expression(checked, node.right)],
      )
    Ast.Expr.Interpolation(node) ->
      parts = node.parts.map do |part: Ast.Part| part_node(checked, part, span) end

      leaf("interpolation", type, span).with(children: parts)
    Ast.Expr.Typed(node) -> expression(checked, node.target)
    Ast.Expr.Case(node) -> case_node(checked, node)
    Ast.Expr.EnumConstructor(node) ->
      leaf("variant", type, span).with(
        target: variant_target(node.enum_name, node.variant_name),
        children: arguments(checked, node.args).concat(named_nodes(checked, node.named)),
      )
    Ast.Expr.FunctionRef(node) ->
      leaf("function", type, span).with(target: node.name, prelude: prelude_of(checked, id))
    Ast.Expr.Invoke(node) ->
      leaf("invoke", type, span).with(text: "call", children: arguments(checked, [node.target].concat(node.args)))
    Ast.Expr.Construct(node) ->
      leaf("struct", type, span).with(target: node.type_name, children: named_nodes(checked, node.args))
    Ast.Expr.Update(node) ->
      children = [expression(checked, node.target)].concat(named_nodes(checked, node.args))
      leaf("with", type, span).with(children: children)
    Ast.Expr.ListLit(node) -> leaf("list", type, span).with(children: arguments(checked, node.elements))
    Ast.Expr.MapLit(node) ->
      entries = node.entries.map do |entry: Ast.MapEntry|
        leaf("entry", Types.Type.Unknown, entry.span).with(
          children: [expression(checked, entry.key), expression(checked, entry.value)],
        )
      end

      leaf("map", type, span).with(children: entries)
    Ast.Expr.BlockLit(node) -> block_literal(checked, node, type)
    Ast.Expr.TypeName(node) -> leaf("type", type, span).with(text: node.name)
    Ast.Expr.ConstRef(node) -> leaf("constant", type, span).with(text: node.name)
    Ast.Expr.RegexLit(node) ->
      leaf("regex", type, span).with(text: "/#{node.body}/#{node.flags}", children: [expression(checked, node.call)])
    Ast.Expr.EagLit(node) -> leaf("template", type, span).with(children: [expression(checked, node.call)])
  end
end

# The linked name of the prelude function that the call `id` runs, or "".
def prelude_of(checked: Checker.Checked, id: Int) -> String
  case checked.bodies.get(id)
    some(key) -> Names.prelude_name(key)
    none -> ""
  end
end

# A call of `target` with the type arguments the checker recorded for it and the prelude function it runs.
def call_leaf(checked: Checker.Checked, id: Int, type: Types.Type, span: Source.Span, target: String) -> Model.Node
  type_args = checked.type_args.get(id).unwrap_or([]).map(&shape)
  leaf("call", type, span).with(target: target, type_args: type_args, prelude: prelude_of(checked, id))
end

# The `name: value` arguments of a struct, a `with` or a variant, in the order written: `text` is the name.
def named_nodes(checked: Checker.Checked, args: List[Ast.NamedArg]) -> List[Model.Node]
  args.map do |arg: Ast.NamedArg|
    value = expression(checked, arg.value)
    leaf("named", Types.Type.Unknown, arg.span).with(type: value.type, text: arg.name, children: [value])
  end
end

# A block or a lambda, `text` saying which was written: one `param` node per parameter, with the type the checker gave
# it, then its body.
def block_literal(checked: Checker.Checked, node: Ast.BlockLit, type: Types.Type) -> Model.Node
  written = "block"
  if node.lambda
    written = "lambda"
  end

  params = node.params.map do |param: Ast.BlockParam|
    leaf("param", Types.Type.Unknown, param.span).with(type: bound(checked, param.id, 0), text: param.name)
  end

  leaf("lambda", type, node.span).with(text: written, children: params.push(block(checked, node.body, node.span)))
end

# A text part has no place of its own, so it takes the place of the interpolation.
def part_node(checked: Checker.Checked, part: Ast.Part, span: Source.Span) -> Model.Node
  case part
    Ast.Part.Text(text) -> leaf("string", Types.Type.String, span).with(text: text)
    Ast.Part.Code(code) -> expression(checked, code)
  end
end

def arguments(checked: Checker.Checked, args: List[Ast.Expr]) -> List[Model.Node]
  args.map do |arg: Ast.Expr| expression(checked, arg) end
end

# The arguments of the call `id`, given in source order. A call with named arguments has them in parameter order, and a
# parameter it leaves out before the last one it gives is a `default` node at the call.
def bound_arguments(checked: Checker.Checked, id: Int, given: List[Ast.Expr], span: Source.Span) -> List[Model.Node]
  slots = checked.slots.get(id).unwrap_or([])
  return arguments(checked, given) if slots.size == 0

  last = 0
  for slot in slots
    if slot > last
      last = slot
    end
  end

  nodes: List[Model.Node] = []
  for param in 0..last
    at = Defaults.argument_for(Defaults.Shape(required: 0, total: 0, fn_last: false), slots, given.size, param)
    if at >= 0
      nodes = nodes.push(expression(checked, given[at]))
    else
      nodes = nodes.push(leaf("default", Types.Type.Unknown, span))
    end
  end

  nodes
end

# The digits of an Int literal too large to stand without its minus, or "".
def huge_digits(expr: Ast.Expr) -> String
  case expr
    Ast.Expr.Literal(node) ->
      case node.value
        Ast.LitValue.Huge(digits) -> digits
        _ -> ""
      end

    _ -> ""
  end
end

def literal_kind(value: Ast.LitValue) -> String
  case value
    Ast.LitValue.Whole(_) -> "int"
    Ast.LitValue.Huge(_) -> "int"
    Ast.LitValue.Real(_) -> "float"
    Ast.LitValue.Text(_) -> "string"
    Ast.LitValue.Flag(_) -> "bool"
    Ast.LitValue.Nothing -> "nil"
  end
end

def literal_text(value: Ast.LitValue) -> String
  case value
    Ast.LitValue.Whole(number) -> "#{number}"
    Ast.LitValue.Huge(digits) -> digits
    Ast.LitValue.Real(number) -> "#{number}"
    Ast.LitValue.Text(text) -> text
    Ast.LitValue.Flag(flag) -> "#{flag}"
    Ast.LitValue.Nothing -> "nil"
  end
end

def leaf(kind: String, type: Types.Type, span: Source.Span) -> Model.Node
  Model.Node(
    kind: kind,
    type: shape(type),
    range: DiagnosticModel.range_of(span),
    text: "",
    target: "",
    new: false,
    children: [],
  )
end

# The place of a statement from its start to the end of its value: the statement's own place runs to the next line.
def through(span: Source.Span, value: Model.Node) -> DiagnosticModel.Region
  DiagnosticModel.Region(start: DiagnosticModel.range_of(span).start, stop: value.range.stop)
end

# The type the checker recorded for the node `id`, Unknown when it has none.
def types_at(checked: Checker.Checked, id: Int) -> Types.Type
  return Types.Type.Unknown if id < 0 or id >= checked.types.size

  checked.types[id]
end

def type_of(checked: Checker.Checked, id: Int) -> Model.TypeShape = shape(types_at(checked, id))

# The type that the node `id` introduced at `at` (a parameter, a binding).
def bound(checked: Checker.Checked, id: Int, at: Int) -> Model.TypeShape
  types = checked.bound.get(id, [])
  return shape(Types.Type.Unknown) if at >= types.size

  shape(types[at])
end

def shape(type: Types.Type) -> Model.TypeShape
  case type
    Types.Type.Struct(name, args) -> Model.TypeShape(kind: "struct", name: name, args: args.map(&shape))
    Types.Type.Enum(name, args) -> Model.TypeShape(kind: "enum", name: name, args: args.map(&shape))
    Types.Type.Opaque(name) -> Model.TypeShape(kind: "opaque", name: name, args: [])
    Types.Type.Var(name) -> Model.TypeShape(kind: "var", name: name, args: [])
    Types.Type.Unknown -> Model.TypeShape(kind: "none", name: "", args: [])
    Types.Type.Fn(params, result) -> builtin("Fn", params.push(result))
    Types.Type.Map(key, value) -> builtin("Map", [key, value])
    Types.Type.ATS(key, value) -> builtin("ATS", [key, value])
    Types.Type.Result(item) -> builtin("Result", [item])
    Types.Type.Optional(item) -> builtin("Optional", [item])
    Types.Type.Task(item) -> builtin("Task", [item])
    Types.Type.Channel(item) -> builtin("Channel", [item])
    Types.Type.Address(item) -> builtin("Address", [item])
    Types.Type.Lazy(item) -> builtin("Lazy", [item])
    Types.Type.Codec(item) -> builtin("Codec", [item])
    Types.Type.List(item) -> builtin("List", [item])
    Types.Type.Set(item) -> builtin("Set", [item])
    Types.Type.Int -> builtin("Int", [])
    Types.Type.Float -> builtin("Float", [])
    Types.Type.Bool -> builtin("Bool", [])
    Types.Type.String -> builtin("String", [])
    Types.Type.Nil -> builtin("Nil", [])
    Types.Type.Void -> builtin("Void", [])
    Types.Type.Json -> builtin("JSON.Value", [])
    Types.Type.Range -> builtin("Range", [])
    Types.Type.Bytes -> builtin("Bytes", [])
  end
end

def builtin(name: String, args: List[Types.Type]) -> Model.TypeShape
  Model.TypeShape(kind: "builtin", name: name, args: args.map(&shape))
end
