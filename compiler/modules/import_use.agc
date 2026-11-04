## CHECK-UNUSED-IMPORT: an import alias that its file never uses is an error (docs/future/26-strict-diagnostics.md,
## 26.1). The linker is the stage that sees the aliases, so it reads the names a file writes, in the tree the parser
## gave, once the rewrite of the file succeeded.
##
## A use is any written name whose first part is the alias: a call, a `&function` value, a type in an annotation, a
## signature, a field or a block parameter, a construction, an enum constructor or a pattern, an enum type, a constant
## (`Alias.NAME`), and the alias of a re-export. A function that nothing calls counts: the rule is about the text.
##
## Two mistakes look like an unused alias and are reported as what they are. An alias written without its member
## (`u: User`, `Domain.Some(1)` with `Domain` an alias) is CHECK-IMPORT-NAME, and a file with a call `Alias.name`
## whose first part is no alias, no name of the file and no builtin module (a mistyped alias) is left to the checker,
## which says CHECK-UNKNOWN-NAME with its "did you mean".

import {ENTRIES} from "../catalog/builtins"
import Ast from "../syntax/ast"
import Walk from "../syntax/ast_walk"
import Source from "../syntax/source"
import Declarations from "declarations"
import Failure from "link_failure"
import Modules from "modules"
import Rewrite from "rewrite"

# What a written name must be: a call or function value (`Call`), a type or an enum (`Type`), where an alias without a
# member is a mistake, or the enum of a variant (`Variant`), which the parser reads from `Alias.Name(...)` too: the
# alias then has a member when its module exports `member`, whatever that is (a struct that is called is the checker's
# to refuse).
enum Role
  Call
  Type
  Variant
  Module
end

# A name as written, the role of the place that wrote it, the span of that place and, for a variant, its name. For a
# `Module` (a regex literal or an EAG template, which need the import of their library in any form) the name is the key
# of that module.
struct Written
  name: String
  role: Role
  span: Source.Span
  member: String
end

## CHECK-UNUSED-IMPORT for the first alias of the file that nothing uses, or CHECK-IMPORT-NAME for an alias written
## without its member. A module read from the stub of the check cache has no bodies to read, and passed this check
## when its entry was made, so it is not checked.
export def check(module: Modules.Module, modules: Map[String, Modules.Module]) -> Result[Bool]
  if module.stubbed
    return ok(true)
  end

  written = of_program(module.program)
  if mistyped_call?(module, written)
    return ok(true)
  end

  try bare_alias(module, modules, written)
  heads: List[String] = []
  for item in written
    if item.name.contains?(".") or item.role == Role.Variant
      heads = heads.push(item.name.split(".")[0])
    end
  end

  for alias in module.aliases.keys
    if written.any? do |item: Written| item.role == Role.Module and item.name == module.aliases[alias] end
      heads = heads.push(alias)
    end
  end

  used = Set.new(heads)
  for decl in module.program.declarations
    case decl
      Ast.Decl.Import(node) ->
        alias = Declarations.alias_of(node)
        if alias != "" and !used.include?(alias) and !reexported?(module, alias)
          return error(unused_failure(module, node, alias))
        end

      _ -> next
    end
  end

  return ok(true)
end

# True when a re-export (`export Alias.name`) names the alias.
def reexported?(module: Modules.Module, alias: String) -> Bool
  return module.program.declarations.any? do |decl: Ast.Decl|
    case decl
      Ast.Decl.Reexport(node) -> return node.alias == alias
      _ -> return false
    end
  end
end

# True when a call is written `Head.name` and Head is nothing the checker would resolve: no alias, no declaration or
# imported name of the file, no builtin module.
def mistyped_call?(module: Modules.Module, written: List[Written]) -> Bool
  return written.any? do |item: Written|
    parts = item.name.split(".")
    return (
      parts.size == 2 and
      item.role == Role.Call and
      !module.aliases.has_key?(parts[0]) and
      !module.names.has_key?(parts[0]) and
      !module.named.has_key?(parts[0]) and
      !ENTRIES.has_key?(item.name)
    )
  end
end

# CHECK-IMPORT-NAME for the first place that writes an alias as a type or an enum with no member after it.
def bare_alias(module: Modules.Module, modules: Map[String, Modules.Module], written: List[Written]) -> Result[Bool]
  ordered = written.sort_by do |entry: Written| entry.span.start.offset end
  for item in ordered
    if without_member?(module, modules, item)
      site = Failure.Site(file: module.file, span: name_span(item))
      help = bare_help(modules[module.aliases[item.name]], item)
      return error(
        Failure.fail_at(
          site,
          "CHECK-IMPORT-NAME",
          "the import alias \"#{item.name}\" needs a member",
          Failure.hint(help),
        ),
      )
    end
  end

  return ok(true)
end

# True when the place writes an import alias with no member: a type or an enum that is the alias, or a variant of an
# enum named like the alias, when the module exports no name of that variant.
def without_member?(module: Modules.Module, modules: Map[String, Modules.Module], item: Written) -> Bool
  if !module.aliases.has_key?(item.name)
    return false
  end

  case item.role
    Role.Type -> return true
    Role.Variant -> return !modules[module.aliases[item.name]].public.has_key?(item.member)
    _ -> return false
  end
end

# What to write instead: the declaration of the same name when the module exports it, and for a variant the enum
# of the module that has it, when there is exactly one.
def bare_help(target: Modules.Module, item: Written) -> String
  if item.role == Role.Variant
    owners = enums_with(target, item.member)
    if owners.size == 1
      return "write #{item.name}.#{owners[0]}.#{item.member}(...)"
    end

    return "write #{item.name}.<Enum>.#{item.member}(...), the enum of #{item.name} that has #{item.member}"
  end

  if target.public.has_key?(item.name)
    return "write #{item.name}.#{item.name}"
  end

  return "write #{item.name}.<Type>, the type or enum that #{item.name} exports"
end

# The exported enums of the module that have a variant of that name.
def enums_with(target: Modules.Module, variant: String) -> List[String]
  out: List[String] = []
  for decl in target.program.declarations
    case Declarations.unwrap(decl)
      Ast.Decl.Enum(node) ->
        if target.public.has_key?(node.name) and node.variants.any? do |each: Ast.EnumVariant| each.name == variant end
          out = out.push(node.name)
        end

      _ -> next
    end
  end

  return out
end

# The span of the name at the start of a place.
def name_span(item: Written) -> Source.Span
  start = item.span.start
  size = item.name.length
  stop = Source.Position(offset: start.offset + size, line: start.line, column: start.column + size)
  return Source.Span(start: start, stop: stop)
end

# CHECK-UNUSED-IMPORT at the alias of the import, with the removal of the line as help.
def unused_failure(module: Modules.Module, node: Ast.ImportDecl, alias: String) -> String
  site = Failure.Site(file: module.file, span: alias_span(module.text, node, alias))
  return Failure.fail_at(
    site,
    "CHECK-UNUSED-IMPORT",
    "the import alias \"#{alias}\" is never used",
    Failure.hint("remove import #{alias} from \"#{node.path}\""),
  )
end

# The span of the alias in its import: the first place of the alias in the text of the line, since `import` comes
# first and is in lower case. The span of the import stands in if the alias is not on the first line.
def alias_span(text: String, node: Ast.ImportDecl, alias: String) -> Source.Span
  start = node.span.start
  size = node.span.stop.offset - start.offset
  if size <= 0 or start.offset + size > text.length
    return node.span
  end

  line = text.slice(start.offset, size).split("\n")[0]
  found = line.index_of(alias)
  if found.none?
    return node.span
  end

  first = Source.Position(offset: start.offset + found.unwrap!, line: start.line, column: start.column + found.unwrap!)
  last = Source.Position(offset: first.offset + alias.length, line: first.line, column: first.column + alias.length)
  return Source.Span(start: first, stop: last)
end

# Every name the declarations of the file write, in the places that can name an alias.
def of_program(program: Ast.Program) -> List[Written]
  out: List[Written] = []
  for decl in program.declarations
    out = out.concat(of_declaration(Declarations.unwrap(decl)))
  end

  return out
end

def of_declaration(decl: Ast.Decl) -> List[Written]
  case decl
    Ast.Decl.Function(node) ->
      out = of_type(node.result, node.type_parameters)
      for param in node.params
        out = out.concat(of_type(param.type, node.type_parameters)).concat(of_optional(param.default))
      end

      return out.concat(of_body(node.body, node.type_parameters))
    Ast.Decl.Struct(node) ->
      out: List[Written] = []
      for field in node.fields
        out = out.concat(of_type(field.type, node.type_parameters)).concat(of_optional(field.default))
      end

      return out
    Ast.Decl.Enum(node) ->
      out: List[Written] = []
      for variant in node.variants
        for type in variant.payload_types
          out = out.concat(of_type(type, node.type_parameters))
        end
      end

      return out
    Ast.Decl.TypeAlias(node) -> return of_type(node.target, node.type_parameters)
    Ast.Decl.Constant(node) -> return of_optional_type(node.type).concat(of_nodes([Walk.Node.Expr(node.value)], []))
    _ -> return []
  end
end

def of_optional(value: Optional[Ast.Expr]) -> List[Written]
  case value
    some(found) -> return of_nodes([Walk.Node.Expr(found)], [])
    none -> return []
  end
end

def of_optional_type(type: Optional[Ast.TypeRef]) -> List[Written]
  case type
    some(found) -> return of_type(found, [])
    none -> return []
  end
end

def of_body(body: List[Ast.Stmt], parameters: List[String]) -> List[Written]
  return of_nodes(body.map do |stmt: Ast.Stmt| Walk.Node.Stmt(stmt) end, parameters)
end

# A type and its arguments. A bare name that is a type parameter of the declaration is no alias.
def of_type(type: Ast.TypeRef, parameters: List[String]) -> List[Written]
  out: List[Written] = []
  if type.name.contains?(".") or !parameters.include?(type.name)
    out = [Written(name: type.name, role: Role.Type, span: type.span, member: "")]
  end

  for arg in type.args
    out = out.concat(of_type(arg, parameters))
  end

  return out
end

# The names of the nodes below `start` and of the nodes themselves, with a worklist and no recursion, like the walk of
# a constant (Walk.references): the tree may be as deep as the parser allows.
def of_nodes(start: List[Walk.Node], parameters: List[String]) -> List[Written]
  out: List[Written] = []
  work = start
  at = 0
  while at < work.size
    node = work[at]
    at += 1
    for found in of_node(node, parameters)
      out = out.push(found)
    end

    for child in Walk.children(node)
      work = work.push(child)
    end
  end

  return out
end

def of_node(node: Walk.Node, parameters: List[String]) -> List[Written]
  case node
    Walk.Node.Expr(expr) -> return of_expr(expr, parameters)
    Walk.Node.Stmt(stmt) -> return of_stmt(stmt)
  end
end

def of_expr(expr: Ast.Expr, parameters: List[String]) -> List[Written]
  case expr
    Ast.Expr.Call(node) -> return [Written(name: node.name, role: Role.Call, span: node.span, member: "")]
    Ast.Expr.FunctionRef(node) -> return [Written(name: node.name, role: Role.Call, span: node.span, member: "")]
    Ast.Expr.EnumConstructor(node) ->
      return [Written(name: node.enum_name, role: Role.Variant, span: node.span, member: node.variant_name)]
    Ast.Expr.RegexLit(node) -> return [library(Rewrite.REGEX_MODULE, node.span)]
    Ast.Expr.EagLit(node) -> return [library(Rewrite.EAG_MODULE, node.span)]
    Ast.Expr.Construct(node) -> return [Written(name: node.type_name, role: Role.Type, span: node.span, member: "")]
    Ast.Expr.TypeName(node) -> return typed_name(node, parameters)
    Ast.Expr.BlockLit(node) ->
      out: List[Written] = []
      for param in node.params
        out = out.concat(of_optional_type(param.type))
      end

      return out
    _ -> return []
  end
end

def library(key: String, span: Source.Span) -> Written
  return Written(name: key, role: Role.Module, span: span, member: "")
end

# A bare type name that is a type parameter in an expression (`T`) is no alias.
def typed_name(node: Ast.TypeName, parameters: List[String]) -> List[Written]
  if !node.name.contains?(".") and parameters.include?(node.name)
    return []
  end

  return [Written(name: node.name, role: Role.Type, span: node.span, member: "")]
end

def of_stmt(stmt: Ast.Stmt) -> List[Written]
  case stmt
    Ast.Stmt.Binding(node) -> return of_optional_type(node.type)
    Ast.Stmt.Case(node) ->
      out: List[Written] = []
      for arm in node.arms
        out = out.concat(of_pattern(arm.pattern))
      end

      return out
    _ -> return []
  end
end

# The enum of a variant pattern and of each variant nested in its slots.
def of_pattern(pattern: Ast.Pattern) -> List[Written]
  case pattern
    Ast.Pattern.Variant(node) ->
      out = [Written(name: node.enum_name, role: Role.Variant, span: node.span, member: node.variant_name)]
      for slot in node.slots
        case slot
          Ast.Slot.Nested(inner) -> out = out.concat(of_pattern(inner))
          _ -> out = out
        end
      end

      return out
    _ -> return []
  end
end
