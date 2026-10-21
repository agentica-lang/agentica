## Where a module names a declaration (docs/future/39-semantic-cli.md, 39.3, `agentica refs`): the name of a call, of a
## `&function` value, of a type in an annotation or a construction, of a struct field in a read, a construction or a
## `with`, of a variant in a constructor or a `case` pattern, of a module constant, and of a builtin. Each place is a
## Site with the Target it stands for.
##
## The linker already resolved every top-level name to the name of the linked program (`@N::name` outside the root
## file), so those names are compared as they are. A field is the pair of its struct and its name; the struct of a read
## is the type that the checker recorded for the target (`Checked.types`), and a method that resolved to a builtin is
## what `Checked.resolved` holds. No source text is matched except to find where a name is written, since the tree
## keeps the span of a whole call or pattern but not of its name. A local is not here: it needs the scopes of
## query/locals.agc.
##
## A module is walked once, with a worklist and no recursion, so a deep tree cannot reach the limit of VM calls.

import Ast from "../syntax/ast"
import CatalogJson from "../catalog/catalog_json"
import Checker from "../check/checker"
import Linker from "../modules/linker"
import Source from "../syntax/source"
import State from "../check/check_state"
import T from "../syntax/types"
import Walk from "../check/const_walk"

# The characters of a name written in the source: a name, a module alias, an enum, a variant.
NAME_CHARS = Set.new("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_?!".split(""))

# The longest dotted name read from the text, in characters.
HEAD_LIMIT = 128

## What a name stands for. `key` tells two targets apart (and is the whole identity); `kind` is `name` for a function,
## struct, enum, type alias, constant or builtin, `field` for a field of the struct `owner`, `variant` for a variant of
## the enum `owner`. `name` is the linked name, or the name of the field or the variant.
export struct Target
  key: String
  kind: String
  owner: String
  name: String
end

## One place that names a Target. `kind` is `definition` (the name where the declaration writes it), `call`, `value`,
## `type`, `construct`, `read` or `pattern`. `span` is the name alone (the last part of `Models.total`); `reach` is the
## whole written name, which a position selects. `function` is the name of the function the site is in, or "".
export struct Site
  target: Target
  kind: String
  span: Source.Span
  reach: Source.Span
  function: String
end

# What the walk of a module knows: what the checker recorded, the linked names the program declares (a name that is
# none of these and no public builtin is not a declaration), `wanted`, the `key` of the one target to keep or "" to
# keep all, the text of the module and the function the walk is in.
struct Scan
  types: List[T.Type]
  resolved: Map[Int, State.Resolved]
  declared: Set[String]
  wanted: String
  text: String
  function: String
end

## The linked names of the top-level declarations of every module.
export def declared_names(modules: List[Linker.LinkedModule]) -> Set[String]
  names: List[String] = []
  for module in modules
    for declaration in module.declarations
      names = names.concat(declaration_names(declaration))
    end
  end
  return Set.new(names)
end

## The sites of `module`, in the order of the text, with those of other targets left out when `wanted` is a key.
export def of_module(
  module: Linker.LinkedModule,
  checked: Checker.Checked,
  declared: Set[String],
  wanted: String,
) -> List[Site]
  scan = Scan(
    types: checked.types,
    resolved: checked.resolved,
    declared: declared,
    wanted: wanted,
    text: module.text,
    function: "",
  )
  out: List[Site] = []
  for declaration in module.declarations
    out = out.concat(declaration_sites(scan, declaration))
  end
  return distinct(out.sort_by do |site: Site| site.reach.start.offset end)
end

## The target of a name that is a top-level declaration (its linked name) or a builtin.
export def named(name: String) -> Target
  return Target(key: "name|#{name}", kind: "name", owner: "", name: name)
end

## The target of the field or variant `name` of the struct or enum `owner` (a linked name); `kind` is `field` or
## `variant`.
export def member(kind: String, owner: String, name: String) -> Target
  return Target(key: "#{kind}|#{owner}|#{name}", kind: kind, owner: owner, name: name)
end

## The target of the imported name that the character at `offset` is on in the import lists of `module`: `make` or
## `create` of `import {make as create} from "models"`. An import is not a reference, but it names a declaration, which
## a query can select. Absent elsewhere, an alias import (`import Models from "models"`) included: it names a module.
export def imported(module: Linker.LinkedModule, offset: Int) -> Ast.Optional[Target]
  for declaration in module.parsed.declarations
    case declaration
      Ast.Decl.Import(node) ->
        for entry in node.names
          on_name = holds(entry.span, offset) or holds(entry.local_span, offset)
          linked = module.named.get(entry.local)
          if on_name and linked.ok?
            return Ast.Optional.Present(named(linked.unwrap!))
          end
        end
      _ -> next
    end
  end
  return Ast.Optional.Absent
end

def declaration_names(declaration: Ast.Decl) -> List[String]
  case declaration
    Ast.Decl.Function(node) -> return [node.name]
    Ast.Decl.Struct(node) -> return [node.name]
    Ast.Decl.Enum(node) -> return [node.name]
    Ast.Decl.TypeAlias(node) -> return [node.name]
    Ast.Decl.Constant(node) -> return [node.name]
    Ast.Decl.Import(_) -> return []
    Ast.Decl.Export(_) -> return []
  end
end

def holds(span: Source.Span, offset: Int) -> Bool
  return span.start.offset <= offset and offset < span.stop.offset
end

# The same name written once is one site: a rewritten `x += 1` or a receiver may carry one span twice.
def distinct(sites: List[Site]) -> List[Site]
  out: List[Site] = []
  for site in sites
    last = out.size - 1
    same = last >= 0 and out[last].reach.start.offset == site.reach.start.offset
    if !(same and out[last].target.key == site.target.key and out[last].kind == site.kind)
      out = out.push(site)
    end
  end
  return out
end

def declaration_sites(scan: Scan, declaration: Ast.Decl) -> List[Site]
  case declaration
    Ast.Decl.Function(node) -> return function_sites(scan.with(function: T.display_name(node.name)), node)
    Ast.Decl.Struct(node) -> return struct_sites(scan, node)
    Ast.Decl.Enum(node) -> return enum_sites(scan, node)
    Ast.Decl.TypeAlias(node) ->
      head = defined(scan, named(node.name), node.name_span)
      return head.concat(type_sites(scan, node.target, node.type_parameters))
    Ast.Decl.Constant(node) ->
      head = defined(scan, named(node.name), node.name_span).concat(optional_type_sites(scan, node.type, []))
      return head.concat(walk(scan, [Walk.Node.Expr(node.value)]))
    Ast.Decl.Import(_) -> return []
    Ast.Decl.Export(_) -> return []
  end
end

def function_sites(scan: Scan, node: Ast.FunctionDecl) -> List[Site]
  out = defined(scan, named(node.name), node.name_span).concat(type_sites(scan, node.result, []))
  roots: List[Walk.Node] = node.body.map do |stmt: Ast.Stmt| Walk.Node.Stmt(stmt) end
  for param in node.params
    out = out.concat(type_sites(scan, param.type, []))
    case param.default
      Ast.Optional.Present(value) -> roots = roots.push(Walk.Node.Expr(value))
      Ast.Optional.Absent -> roots = roots
    end
  end
  return out.concat(walk(scan, roots))
end

def struct_sites(scan: Scan, node: Ast.StructDecl) -> List[Site]
  out = defined(scan, named(node.name), node.name_span)
  for field in node.fields
    out = out.concat(defined(scan, member("field", node.name, field.name), field.name_span))
    out = out.concat(type_sites(scan, field.type, []))
  end
  return out
end

# A type parameter of the enum stays as it is in a payload (`Full(T)`): it names no declaration.
def enum_sites(scan: Scan, node: Ast.EnumDecl) -> List[Site]
  out = defined(scan, named(node.name), node.name_span)
  for variant in node.variants
    out = out.concat(defined(scan, member("variant", node.name, variant.name), variant.name_span))
    for payload in variant.payload_types
      out = out.concat(type_sites(scan, payload, node.type_parameters))
    end
  end
  return out
end

def defined(scan: Scan, target: Target, span: Source.Span) -> List[Site]
  return placed(scan, target, "definition", span, span)
end

def placed(scan: Scan, target: Target, kind: String, span: Source.Span, reach: Source.Span) -> List[Site]
  if scan.wanted != "" and scan.wanted != target.key
    return []
  end
  return [Site(target: target, kind: kind, span: span, reach: reach, function: scan.function)]
end

# Every expression and statement below the roots.
def walk(scan: Scan, roots: List[Walk.Node]) -> List[Site]
  out: List[Site] = []
  work = roots
  at = 0
  while at < work.size
    node = work[at]
    at += 1
    case node
      Walk.Node.Expr(expr) -> out = out.concat(expression_sites(scan, expr))
      Walk.Node.Stmt(stmt) -> out = out.concat(statement_sites(scan, stmt))
    end
    work = work.concat(Walk.children(node))
  end
  return out
end

def statement_sites(scan: Scan, stmt: Ast.Stmt) -> List[Site]
  case stmt
    Ast.Stmt.Binding(node) -> return optional_type_sites(scan, node.type, [])
    Ast.Stmt.Case(node) ->
      out: List[Site] = []
      for arm in node.arms
        out = out.concat(pattern_sites(scan, arm.pattern))
      end
      return out
    _ -> return []
  end
end

def expression_sites(scan: Scan, expr: Ast.Expr) -> List[Site]
  case expr
    Ast.Expr.Call(node) -> return name_sites(scan, node.name, node.span.start, "call")
    Ast.Expr.FunctionRef(node) -> return name_sites(scan, node.name, after(node.span.start, 1), "value")
    Ast.Expr.ConstRef(node) -> return placed(scan, named(node.name), "value", node.span, node.span)
    Ast.Expr.TypeName(node) -> return type_name_sites(scan, node.name, node.span.start, "type")
    Ast.Expr.EnumConstructor(node) ->
      return enum_part_sites(scan, node.enum_name, node.variant_name, node.span, "construct")
    Ast.Expr.Construct(node) ->
      return type_name_sites(scan, node.type_name, node.span.start, "construct").concat(
        field_sites(scan, node.type_name, node.args, "construct"),
      )
    Ast.Expr.Update(node) -> return field_sites(scan, struct_of(scan, node.target), node.args, "construct")
    Ast.Expr.FieldAccess(node) -> return access_sites(scan, node.id, node.target, node.name, node.name_span)
    Ast.Expr.MethodCall(node) -> return builtin_method_sites(scan, node.id, node.name_span)
    Ast.Expr.BlockLit(node) ->
      out: List[Site] = []
      for param in node.params
        out = out.concat(optional_type_sites(scan, param.type, []))
      end
      return out
    _ -> return []
  end
end

# `x.name`: a method that resolved to a builtin, else a field of the struct that the target is.
def access_sites(scan: Scan, id: Int, target: Ast.Expr, name: String, name_span: Source.Span) -> List[Site]
  if scan.resolved.has_key?(id)
    return builtin_method_sites(scan, id, name_span)
  end
  owner = struct_of(scan, target)
  if !scan.declared.include?(owner)
    return []
  end
  return placed(scan, member("field", owner, name), "read", name_span, name_span)
end

def builtin_method_sites(scan: Scan, id: Int, name_span: Source.Span) -> List[Site]
  found = scan.resolved.get(id)
  if !found.ok?
    return []
  end
  case found.unwrap!
    State.Resolved.Call(name, _) ->
      if CatalogJson.public(name).ok?
        return placed(scan, named(name), "call", name_span, name_span)
      end
      return []
    _ -> return []
  end
end

# The linked name of the struct that the checker gave the expression as its type; "" when there is none.
def struct_of(scan: Scan, target: Ast.Expr) -> String
  id = Ast.expr_id(target)
  if id < scan.types.size
    return T.name(scan.types[id])
  end
  return ""
end

# The name of a function (a call, a `&f`) or of a builtin, written from `start`.
def name_sites(scan: Scan, name: String, start: Source.Position, kind: String) -> List[Site]
  user = scan.declared.include?(name)
  if !user and !CatalogJson.public(name).ok?
    return []
  end
  parts = written(scan.text, start)
  if parts.size == 0
    return []
  end
  whole = Source.Span(start: parts[0].start, stop: parts[parts.size - 1].stop)
  if user
    return placed(scan, named(name), kind, parts[parts.size - 1], whole)
  end
  # A builtin is named with its namespace (`File.read`), which is part of the name.
  return placed(scan, named(name), kind, whole, whole)
end

# The name of a declared type written from `start`.
def type_name_sites(scan: Scan, name: String, start: Source.Position, kind: String) -> List[Site]
  if !scan.declared.include?(name)
    return []
  end
  parts = written(scan.text, start)
  if parts.size == 0
    return []
  end
  last = parts[parts.size - 1]
  return placed(scan, named(name), kind, last, Source.Span(start: parts[0].start, stop: last.stop))
end

# `Shape.Circle` (or `Models.Shape.Circle`) written from the start of `span`: the enum is the part before the last, the
# variant the last. A position on the module alias or the enum selects the enum.
def enum_part_sites(
  scan: Scan,
  enum_name: String,
  variant_name: String,
  span: Source.Span,
  kind: String,
) -> List[Site]
  parts = written(scan.text, span.start)
  if !scan.declared.include?(enum_name) or parts.size < 2
    return []
  end
  enum_part = parts[parts.size - 2]
  variant_part = parts[parts.size - 1]
  reach = Source.Span(start: parts[0].start, stop: enum_part.stop)
  return placed(scan, named(enum_name), kind, enum_part, reach).concat(
    placed(scan, member("variant", enum_name, variant_name), kind, variant_part, variant_part),
  )
end

# The names of `name: value` pairs, which start at the name.
def field_sites(scan: Scan, owner: String, args: List[Ast.NamedArg], kind: String) -> List[Site]
  out: List[Site] = []
  if !scan.declared.include?(owner)
    return out
  end
  for arg in args
    span = Source.Span(start: arg.span.start, stop: after(arg.span.start, arg.name.length))
    out = out.concat(placed(scan, member("field", owner, arg.name), kind, span, span))
  end
  return out
end

# The variants named by a pattern, nested patterns included.
def pattern_sites(scan: Scan, pattern: Ast.Pattern) -> List[Site]
  out: List[Site] = []
  work = [pattern]
  at = 0
  while at < work.size
    case work[at]
      Ast.Pattern.Variant(node) ->
        out = out.concat(enum_part_sites(scan, node.enum_name, node.variant_name, node.span, "pattern"))
        for slot in node.slots
          case slot
            Ast.Slot.Nested(inner) -> work = work.push(inner)
            _ -> work = work
          end
        end
      _ -> work = work
    end
    at += 1
  end
  return out
end

def optional_type_sites(scan: Scan, type: Ast.Optional[Ast.TypeRef], parameters: List[String]) -> List[Site]
  case type
    Ast.Optional.Present(found) -> return type_sites(scan, found, parameters)
    Ast.Optional.Absent -> return []
  end
end

# The declared types named in an annotation, type arguments included. `parameters` are type parameters, which name no
# declaration even if the program declares a type of the same name.
def type_sites(scan: Scan, type: Ast.TypeRef, parameters: List[String]) -> List[Site]
  out: List[Site] = []
  work = [type]
  at = 0
  while at < work.size
    ref = work[at]
    at += 1
    if ref.args.size > 0 or !parameters.any? do |parameter: String| parameter == ref.name end
      out = out.concat(type_name_sites(scan, ref.name, ref.span.start, "type"))
    end
    work = work.concat(ref.args)
  end
  return out
end

# The position `count` characters further on the same line.
def after(start: Source.Position, count: Int) -> Source.Position
  return Source.Position(offset: start.offset + count, line: start.line, column: start.column + count)
end

# The dotted name that the text holds from `start`, one span for each name between dots (`Models.User` has two). Only
# the first line of the name is read, which is where an alias, an enum and a variant are written.
def written(text: String, start: Source.Position) -> List[Source.Span]
  parts: List[Source.Span] = []
  first = start.offset
  from = 0
  at = 0
  while at <= HEAD_LIMIT and first + at < text.length
    character = text.at(first + at)
    if character == "."
      parts = piece(parts, start, from, at)
      from = at + 1
    elsif !NAME_CHARS.include?(character)
      break
    end
    at += 1
  end
  return piece(parts, start, from, at)
end

# Adds the span from `from` to `to` (excluded), counted from `start`, when it holds a character.
def piece(parts: List[Source.Span], start: Source.Position, from: Int, to: Int) -> List[Source.Span]
  if to <= from
    return parts
  end
  span = Source.Span(start: after(start, from), stop: after(start, to))
  return parts.push(span)
end
