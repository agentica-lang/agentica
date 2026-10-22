## Registration: the first four passes of `check`, which read every declaration of the program in
## order and fill the tables of Cx before any function body is checked: the names of the enums, the structs and their
## fields, the variants of the enums, and the signatures of the functions. Then check_main. A problem is
## CHECK-REDEFINED-NAME, CHECK-VOID-TYPE or another type problem, or CHECK-MAIN.

import Model from "../catalog/builtin_model"
import {ENTRIES, RESERVED} from "../catalog/builtins"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import T from "../syntax/types"
import DefaultChecks from "check_defaults"
import State from "check_state"
import Types from "check_types"
import Defaults from "defaults"

## The context with the enums, structs and functions of the program added to the builtin ones.
export def register(cx: State.Cx, modules: List[Linker.LinkedModule]) -> Result[State.Cx]
  found = try register_resources(cx, modules)
  found = try register_aliases(found, modules)
  found = try register_enum_names(found, modules)
  found = try register_structs(found, modules)
  try check_alias_targets(found, modules)
  found = try register_enum_variants(found, modules)
  found = try register_functions(found, modules)
  return ok(found)
end

## CHECK-MAIN unless the program declares main() -> Void. Only the modules whose key is in `roots` count (a `main` of
## an imported file does not), and the first main of each is the one that counts; a query that links several roots
## checks each. root is the span of the program. When `required` is false a program with no main passes, but a main
## that is declared still has to have the signature.
export def check_main(
  cx: State.Cx,
  modules: List[Linker.LinkedModule],
  roots: List[String],
  root: Source.Span,
  required: Bool,
) -> Result[Bool]
  st = State.fresh()
  found = false
  for module in modules
    if roots.any? do |key: String| key == module.key end
      case main_of(module)
        Ast.Optional.Present(node) ->
          try main_signature(cx.with(file: module.file), st, node)
          found = true
        Ast.Optional.Absent -> found = found
      end
    end
  end
  if found or !required
    return ok(true)
  end
  return error(
    State.fail(
      cx.with(file: modules[0].file),
      st,
      "CHECK-MAIN",
      "a program must declare exactly one main() -> Void",
      root,
    ),
  )
end

# The resources of the extern blocks: nominal types with no structure, which every later pass may name.
def register_resources(cx: State.Cx, modules: List[Linker.LinkedModule]) -> Result[State.Cx]
  st = State.fresh()
  found = cx
  for module in modules
    for decl in module.declarations
      case decl
        Ast.Decl.Resource(node) ->
          here = found.with(file: module.file)
          try check_new_name(here, st, node.name, node.name_span)
          found = here.with(resources: here.resources.add(node.name))
        _ -> st = st
      end
    end
  end
  return ok(found)
end

def register_aliases(cx: State.Cx, modules: List[Linker.LinkedModule]) -> Result[State.Cx]
  st = State.fresh()
  found = cx
  for module in modules
    for decl in module.declarations
      case decl
        Ast.Decl.TypeAlias(node) ->
          here = found.with(file: module.file)
          try check_new_name(here, st, node.name, node.name_span)
          try check_type_parameters(here, st, node.type_parameters, "type alias", node.span)
          found = here.with(aliases: here.aliases.put(node.name, node))
        _ -> st = st
      end
    end
  end
  return ok(found)
end

def check_alias_targets(cx: State.Cx, modules: List[Linker.LinkedModule]) -> Result[Bool]
  st = State.fresh()
  for module in modules
    here = cx.with(file: module.file)
    for decl in module.declarations
      case decl
        Ast.Decl.TypeAlias(node) -> try Types.resolve_type(Types.alias_scope(here, node), st, node.target, true)
        _ -> st = st
      end
    end
  end
  return ok(true)
end

# The first function of the module called main; a prefixed name (a root of several roots) counts by its own name.
def main_of(module: Linker.LinkedModule) -> Ast.Optional[Ast.FunctionDecl]
  for decl in module.declarations
    case decl
      Ast.Decl.Function(node) ->
        if T.display_name(node.name) == "main"
          return Ast.Optional.Present(node)
        end
      _ -> next
    end
  end
  return Ast.Optional.Absent
end

def main_signature(cx: State.Cx, st: State.St, node: Ast.FunctionDecl) -> Result[Bool]
  result = try Types.resolve_type(cx, st, node.result, true)
  if node.params.size != 0 or !T.is?(result, "Void")
    return error(State.fail(cx, st, "CHECK-MAIN", "main must take no parameters and return Void", node.span))
  end
  return ok(true)
end

# The enum names, with their type parameters and no variants yet.
def register_enum_names(cx: State.Cx, modules: List[Linker.LinkedModule]) -> Result[State.Cx]
  st = State.fresh()
  found = cx
  for module in modules
    for decl in module.declarations
      case decl
        Ast.Decl.Enum(node) -> found = try register_enum_name(found.with(file: module.file), st, node)
        _ -> st = st
      end
    end
  end
  return ok(found)
end

def register_enum_name(cx: State.Cx, st: State.St, node: Ast.EnumDecl) -> Result[State.Cx]
  try check_new_name(cx, st, node.name, node.span)
  try check_type_parameters(cx, st, node.type_parameters, "enum", node.span)
  return ok(
    cx.with(
      enums: cx.enums.put(node.name, Model.EnumDef(name: node.name, parameters: node.type_parameters, variants: [])),
    ),
  )
end

# CHECK-REDEFINED-NAME when the type parameters of an enum or a generic alias (owner) repeat a name or take a reserved
# one. Both follow the same rule.
def check_type_parameters(
  cx: State.Cx,
  st: State.St,
  parameters: List[String],
  owner: String,
  span: Source.Span,
) -> Result[Bool]
  seen: Set[String] = Set.new([])
  for parameter in parameters
    if seen.include?(parameter)
      return error(State.fail(cx, st, "CHECK-REDEFINED-NAME", "duplicate #{owner} type parameter", span))
    end
    seen = seen.add(parameter)
  end
  for parameter in parameters
    if RESERVED.include?(parameter)
      return error(
        State.fail(
          cx,
          st,
          "CHECK-REDEFINED-NAME",
          "\"#{parameter}\" cannot be used as #{article(owner)} #{owner} type parameter",
          span,
        ),
      )
    end
  end
  return ok(true)
end

def article(owner: String) -> String
  if owner == "enum"
    return "an"
  end
  return "a"
end

# CHECK-REDEFINED-NAME when a declared type name is reserved or already taken.
def check_new_name(cx: State.Cx, st: State.St, name: String, span: Source.Span) -> Result[Bool]
  if (
    RESERVED.include?(name) or
    cx.structs.has_key?(name) or
    cx.enums.has_key?(name) or
    cx.aliases.has_key?(name) or
    cx.resources.include?(name) or
    cx.functions.has_key?(name)
  )
    return error(
      State.fail(cx, st, "CHECK-REDEFINED-NAME", "\"#{T.display_name(name)}\" is already defined", span),
    )
  end
  return ok(true)
end

# The struct names first, with no fields, so a field may name a struct declared later; then the fields.
def register_structs(cx: State.Cx, modules: List[Linker.LinkedModule]) -> Result[State.Cx]
  st = State.fresh()
  found = cx
  for module in modules
    for decl in module.declarations
      case decl
        Ast.Decl.Struct(node) ->
          here = found.with(file: module.file)
          try check_new_name(here, st, node.name, node.span)
          found = here.with(structs: found.structs.put(node.name, []))
        _ -> st = st
      end
    end
  end
  for module in modules
    for decl in module.declarations
      case decl
        Ast.Decl.Struct(node) -> found = try register_fields(found.with(file: module.file), st, node)
        _ -> st = st
      end
    end
  end
  return ok(found)
end

def register_fields(cx: State.Cx, st: State.St, node: Ast.StructDecl) -> Result[State.Cx]
  seen: Set[String] = Set.new([])
  fields: List[Model.Named] = []
  for field in node.fields
    try State.reserve_constructor(cx, st, field.name, field.span)
    if seen.include?(field.name)
      return error(State.fail(cx, st, "CHECK-REDEFINED-NAME", "duplicate field \"#{field.name}\"", field.span))
    end
    seen = seen.add(field.name)
    type = try Types.resolve_type(cx, st, field.type, false)
    # value.with(...) is always the struct update, so a function field named with could never be called without .call.
    if field.name == "with" and T.is?(type, "Fn")
      return error(
        State.fail_help(
          cx,
          st,
          "CHECK-REDEFINED-NAME",
          "a field named \"with\" cannot hold a function",
          field.span,
          "value.with(...) is the struct update; rename the field",
        ),
      )
    end
    fields = fields.push(Model.Named(name: field.name, type: type))
  end
  return ok(cx.with(structs: cx.structs.put(node.name, fields)))
end

def register_enum_variants(cx: State.Cx, modules: List[Linker.LinkedModule]) -> Result[State.Cx]
  st = State.fresh()
  found = cx
  for module in modules
    for decl in module.declarations
      case decl
        Ast.Decl.Enum(node) -> found = try register_variants(found.with(file: module.file), st, node)
        _ -> st = st
      end
    end
  end
  return ok(found)
end

# The variants of one enum, resolved with the enum's type parameters in scope.
def register_variants(cx: State.Cx, st: State.St, node: Ast.EnumDecl) -> Result[State.Cx]
  here = cx.with(type_params: node.type_parameters)
  seen: Set[String] = Set.new([])
  variants: List[Model.Variant] = []
  for variant in node.variants
    if seen.include?(variant.name)
      return error(
        State.fail(
          here,
          st,
          "CHECK-REDEFINED-NAME",
          "duplicate variant \"#{variant.name}\" in enum \"#{T.display_name(node.name)}\"",
          variant.span,
        ),
      )
    end
    seen = seen.add(variant.name)
    payload = try Types.resolve_all(here, st, variant.payload_types)
    variants = variants.push(Model.Variant(name: variant.name, payload: payload))
  end
  definition = Model.EnumDef(name: node.name, parameters: node.type_parameters, variants: variants)
  return ok(cx.with(enums: cx.enums.put(node.name, definition)))
end

def register_functions(cx: State.Cx, modules: List[Linker.LinkedModule]) -> Result[State.Cx]
  st = State.fresh()
  found = cx
  for module in modules
    for decl in module.declarations
      case decl
        Ast.Decl.Function(node) -> found = try register_function(found.with(file: module.file), st, node)
        _ -> st = st
      end
    end
  end
  return ok(found)
end

def register_function(cx: State.Cx, st: State.St, node: Ast.FunctionDecl) -> Result[State.Cx]
  taken = (
    ENTRIES.has_key?(node.name) or
    cx.functions.has_key?(node.name) or
    cx.structs.has_key?(node.name) or
    cx.enums.has_key?(node.name) or
    cx.aliases.has_key?(node.name)
  )
  if taken
    return error(
      State.fail(
        cx,
        st,
        "CHECK-REDEFINED-NAME",
        "\"#{T.display_name(node.name)}\" is already defined",
        node.span,
      ),
    )
  end
  seen: Set[String] = Set.new([])
  params: List[T.Type] = []
  for param in node.params
    if param.name != "_" and seen.include?(param.name)
      return error(
        State.fail(cx, st, "CHECK-REDEFINED-NAME", "duplicate parameter \"#{param.name}\"", param.span),
      )
    end
    seen = seen.add(param.name)
    params = params.push(try Types.resolve_type(cx, st, param.type, false))
  end
  try DefaultChecks.check_parameters(cx, st, node)
  result = try Types.resolve_type(cx, st, node.result, true)
  signature = State.Signature(params: params, result: result, shape: Defaults.shape(node.params))
  return ok(cx.with(functions: cx.functions.put(node.name, signature)))
end
