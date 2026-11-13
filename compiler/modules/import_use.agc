## CHECK-UNUSED-IMPORT: an import alias that its file never uses is an error (docs/grammar/05b-modules.md,
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

## CHECK-UNUSED-IMPORT for the first alias of the file that nothing uses, or CHECK-IMPORT-NAME for an alias written
## without its member. A module read from the stub of the check cache has no bodies to read, and passed this check
## when its entry was made, so it is not checked. With `unused` false (a query about this file, whose editor adds the
## import before the code that uses it) only CHECK-IMPORT-NAME is reported: the other rule is skipped.
def check(module: Modules.Module, modules: Map[String, Modules.Module], unused: Bool) -> Result[Bool]
  return ok(true) if module.stubbed

  written = of_program(module.program)
  return ok(true) if mistyped_call?(module, written)

  try bare_alias(module, modules, written)
  return ok(true) if !unused

  heads: List[String] = []
  libraries: List[String] = []
  # A module block sees the imports of its file, so what it writes uses them too; the block's own module checks the
  # rest of what it writes.
  for item in written.concat(of_blocks(module.program))
    if item.role == Role.Module
      libraries = libraries.push(item.name)
    elsif item.name.include?(".") or item.role == Role.Variant
      heads = heads.push(item.name.split(".")[0])
    end
  end

  # A regex literal or a template uses every alias of the module it needs.
  needed = Set.new(libraries)
  for alias in module.aliases.keys
    if needed.include?(module.aliases[alias])
      heads = heads.push(alias)
    end
  end

  for decl in module.program.declarations
    case decl
      Ast.Decl.Reexport(node) -> heads = heads.push(node.alias)
      _ -> next
    end
  end

  used = Set.new(heads)
  for decl in module.program.declarations
    case decl
      Ast.Decl.Import(node) ->
        alias = Declarations.alias_of(node)
        return error(unused_failure(module, node, alias)) if alias != "" and !used.include?(alias)

      _ -> next
    end
  end

  ok(true)
end

private

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

# True when a call is written `Head.name` and Head is nothing the checker would resolve: no alias, no declaration or
# imported name of the file, no builtin module.
def mistyped_call?(module: Modules.Module, written: List[Written]) -> Bool
  written.any? do |item: Written|
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

  ok(true)
end

# True when the place writes an import alias with no member: a type or an enum that is the alias, or a variant of an
# enum named like the alias, when the module exports no name of that variant.
def without_member?(module: Modules.Module, modules: Map[String, Modules.Module], item: Written) -> Bool
  return false if !module.aliases.has_key?(item.name)

  case item.role
    Role.Type -> true
    Role.Variant -> !modules[module.aliases[item.name]].public.has_key?(item.member)
    _ -> false
  end
end

# What to write instead: the declaration of the same name when the module exports it, and for a variant the enum
# of the module that has it, when there is exactly one.
def bare_help(target: Modules.Module, item: Written) -> String
  if item.role == Role.Variant
    owners = enums_with(target, item.member)
    return "write #{item.name}.#{owners[0]}.#{item.member}(...)" if owners.size == 1

    return "write #{item.name}.<Enum>.#{item.member}(...), the enum of #{item.name} that has #{item.member}"
  end

  return "write #{item.name}.#{item.name}" if target.public.has_key?(item.name)

  "write #{item.name}.<Type>, the type or enum that #{item.name} exports"
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

  out
end

# The span of the name at the start of a place.
def name_span(item: Written) -> Source.Span
  start = item.span.start
  size = item.name.length
  stop = Source.Position(offset: start.offset + size, line: start.line, column: start.column + size)
  Source.Span(start: start, stop: stop)
end

# CHECK-UNUSED-IMPORT at the alias of the import, with the removal of the line as help.
def unused_failure(module: Modules.Module, node: Ast.ImportDecl, alias: String) -> String
  site = Failure.Site(file: module.file, span: alias_span(module.text, node, alias))
  Failure.fail_at(
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
  return node.span if size <= 0 or start.offset + size > text.length

  line = text.slice(start.offset, size).split("\n")[0]
  found = line.index_of(alias)
  return node.span if found.none?

  first = Source.Position(offset: start.offset + found.unwrap!, line: start.line, column: start.column + found.unwrap!)
  last = Source.Position(offset: first.offset + alias.length, line: first.line, column: first.column + alias.length)
  Source.Span(start: first, stop: last)
end

# Every name the declarations of the file write, in the places that can name an alias. Each function below takes the
# names found so far and gives them back with its own pushed on, so no list is copied while the file is walked.
def of_program(program: Ast.Program) -> List[Written]
  out: List[Written] = []
  for decl in program.declarations
    out = of_declaration(out, Declarations.unwrap(decl))
  end

  out
end

# Every name the module blocks of the file write.
def of_blocks(program: Ast.Program) -> List[Written]
  out: List[Written] = []
  for decl in program.declarations
    case Declarations.unwrap(decl)
      Ast.Decl.Module(node) -> out = out.concat(of_program(program.with(declarations: node.declarations)))
      _ -> next
    end
  end

  out
end

def of_declaration(found: List[Written], decl: Ast.Decl) -> List[Written]
  out = found
  case decl
    Ast.Decl.Function(node) ->
      out = of_type(out, node.result, node.type_parameters)
      for param in node.params
        out = of_type(out, param.type, node.type_parameters)
        out = of_optional(out, param.default, node.type_parameters)
      end

      of_nodes(out, node.body.map do |stmt: Ast.Stmt| Walk.Node.Stmt(stmt) end, node.type_parameters)
    Ast.Decl.Struct(node) ->
      for field in node.fields
        out = of_type(out, field.type, node.type_parameters)
        out = of_optional(out, field.default, node.type_parameters)
      end

      out
    Ast.Decl.Enum(node) ->
      for variant in node.variants
        for type in variant.payload_types
          out = of_type(out, type, node.type_parameters)
        end
      end

      out
    Ast.Decl.TypeAlias(node) -> of_type(out, node.target, node.type_parameters)
    Ast.Decl.Constant(node) ->
      out = of_optional_type(out, node.type, [])
      of_nodes(out, [Walk.Node.Expr(node.value)], [])
    _ -> out
  end
end

def of_optional(found: List[Written], value: Optional[Ast.Expr], parameters: List[String]) -> List[Written]
  case value
    some(expr) -> of_nodes(found, [Walk.Node.Expr(expr)], parameters)
    none -> found
  end
end

def of_optional_type(found: List[Written], type: Optional[Ast.TypeRef], parameters: List[String]) -> List[Written]
  case type
    some(ref) -> of_type(found, ref, parameters)
    none -> found
  end
end

# A type and its arguments. A bare name that is a type parameter in scope is no alias.
def of_type(found: List[Written], type: Ast.TypeRef, parameters: List[String]) -> List[Written]
  out = found
  if type.name.include?(".") or !parameters.include?(type.name)
    out = out.push(Written(name: type.name, role: Role.Type, span: type.span, member: ""))
  end

  for arg in type.args
    out = of_type(out, arg, parameters)
  end

  out
end

# The names of the nodes in `start` and below them, with a worklist and no recursion, like the walk of a constant
# (Walk.references): the tree may be as deep as the parser allows.
def of_nodes(found: List[Written], start: List[Walk.Node], parameters: List[String]) -> List[Written]
  out = found
  work = start
  at = 0
  while at < work.size
    node = work[at]
    at += 1
    out = of_node(out, node, parameters)
    for child in Walk.children(node)
      work = work.push(child)
    end
  end

  out
end

def of_node(found: List[Written], node: Walk.Node, parameters: List[String]) -> List[Written]
  case node
    Walk.Node.Expr(expr) -> of_expr(found, expr, parameters)
    Walk.Node.Stmt(stmt) -> of_stmt(found, stmt, parameters)
  end
end

def of_expr(found: List[Written], expr: Ast.Expr, parameters: List[String]) -> List[Written]
  case expr
    Ast.Expr.Call(node) -> found.push(Written(name: node.name, role: Role.Call, span: node.span, member: ""))
    Ast.Expr.FunctionRef(node) -> found.push(Written(name: node.name, role: Role.Call, span: node.span, member: ""))
    Ast.Expr.EnumConstructor(node) ->
      found.push(Written(name: node.enum_name, role: Role.Variant, span: node.span, member: node.variant_name))
    Ast.Expr.RegexLit(node) -> found.push(library(Rewrite.REGEX_MODULE, node.span))
    Ast.Expr.EagLit(node) -> found.push(library(Rewrite.EAG_MODULE, node.span))
    Ast.Expr.Construct(node) -> found.push(Written(name: node.type_name, role: Role.Type, span: node.span, member: ""))
    Ast.Expr.TypeName(node) -> typed_name(found, node, parameters)
    Ast.Expr.BlockLit(node) ->
      out = found
      for param in node.params
        out = of_optional_type(out, param.type, parameters)
      end

      out
    Ast.Expr.Case(node) -> of_case(found, node)
    _ -> found
  end
end

def library(key: String, span: Source.Span) -> Written = Written(name: key, role: Role.Module, span: span, member: "")

# A bare type name that is a type parameter in an expression (`T`) is no alias.
def typed_name(found: List[Written], node: Ast.TypeName, parameters: List[String]) -> List[Written]
  if node.args.size > 0
    return of_type(found, Ast.TypeRef(id: node.id, name: node.name, args: node.args, span: node.span), parameters)
  end

  return found if !node.name.include?(".") and parameters.include?(node.name)

  found.push(Written(name: node.name, role: Role.Type, span: node.span, member: ""))
end

def of_stmt(found: List[Written], stmt: Ast.Stmt, parameters: List[String]) -> List[Written]
  case stmt
    Ast.Stmt.Binding(node) -> of_optional_type(found, node.type, parameters)
    Ast.Stmt.Case(node) -> of_case(found, node)
    _ -> found
  end
end

def of_case(found: List[Written], node: Ast.CaseStmt) -> List[Written]
  out = found
  for arm in node.arms
    out = of_pattern(out, arm.pattern)
  end

  out
end

# The enum of a variant pattern and of each variant nested in its slots.
def of_pattern(found: List[Written], pattern: Ast.Pattern) -> List[Written]
  case pattern
    Ast.Pattern.Variant(node) ->
      out = found.push(Written(name: node.enum_name, role: Role.Variant, span: node.span, member: node.variant_name))
      for slot in node.slots
        case slot
          Ast.Slot.Nested(inner) -> out = of_pattern(out, inner)
          _ -> out = out
        end
      end

      out
    Ast.Pattern.Or(node) ->
      out = found
      for inner in node.patterns
        out = of_pattern(out, inner)
      end

      out
    _ -> found
  end
end
