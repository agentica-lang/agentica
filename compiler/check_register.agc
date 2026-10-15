## Registration: the first four passes of `check` in src/checker.rkt, which read every declaration of the program in order and fill the tables of Cx before any function body is checked: the names of the enums, the structs and their fields, the variants of the enums, and the signatures of the functions. Then check_main. A problem is CHECK-REDEFINED-NAME, CHECK-VOID-TYPE or another type problem, or CHECK-MAIN.

import "ast" as Ast
import "builtin_model" as Model
import "check_state" as State
import "check_types" as Types
import "linker" as Linker
import "source" as Source
import "types" as T

## The context with the enums, structs and functions of the program added to the builtin ones.
export def register(cx: State.Cx, modules: List[Linker.LinkedModule]) -> Result[State.Cx]
  found = try register_enum_names(cx, modules)
  found = try register_structs(found, modules)
  found = try register_enum_variants(found, modules)
  found = try register_functions(found, modules)
  return ok(found)
end

## CHECK-MAIN unless the program declares main() -> Void; the first main is the one that counts. root is the span of the program.
export def check_main(cx: State.Cx, modules: List[Linker.LinkedModule], root: Source.Span) -> Result[Bool]
  st = State.fresh()
  for module in modules
    for decl in module.declarations
      case decl
        Ast.Decl.Function(node) ->
          if node.name == "main"
            return main_signature(cx.with(file: module.file), st, node)
          end
        _ -> st = st
      end
    end
  end
  return error(State.fail(cx.with(file: modules[0].file), st, "CHECK-MAIN", "a program must declare exactly one main() -> Void", root))
end

def main_signature(cx: State.Cx, st: State.St, node: Ast.FunctionDecl) -> Result[Bool]
  result = try Types.resolve_type(cx, st, node.result, true)
  if node.params.size != 0 or !T.is(result, "Void")
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
  seen: Set[String] = Set.new([])
  for parameter in node.type_parameters
    if seen.include?(parameter)
      return error(State.fail(cx, st, "CHECK-REDEFINED-NAME", "duplicate enum type parameter", node.span))
    end
    seen = seen.add(parameter)
  end
  for parameter in node.type_parameters
    if cx.catalog.reserved.include?(parameter)
      return error(State.fail(cx, st, "CHECK-REDEFINED-NAME", "\"" + parameter + "\" cannot be used as an enum type parameter", node.span))
    end
  end
  return ok(cx.with(enums: cx.enums.put(node.name, Model.EnumDef(name: node.name, parameters: node.type_parameters, variants: []))))
end

# CHECK-REDEFINED-NAME when a struct or enum name is reserved or already taken.
def check_new_name(cx: State.Cx, st: State.St, name: String, span: Source.Span) -> Result[Bool]
  if cx.catalog.reserved.include?(name) or cx.structs.has_key?(name) or cx.enums.has_key?(name) or cx.functions.has_key?(name)
    return error(State.fail(cx, st, "CHECK-REDEFINED-NAME", "\"" + T.display_name(name) + "\" is already defined", span))
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
      return error(State.fail(cx, st, "CHECK-REDEFINED-NAME", "duplicate field \"" + field.name + "\"", field.span))
    end
    seen = seen.add(field.name)
    type = try Types.resolve_type(cx, st, field.type, false)
    # value.with(...) is always the struct update, so a function field named with could never be called without .call.
    if field.name == "with" and T.is(type, "Fn")
      return error(State.fail_help(cx, st, "CHECK-REDEFINED-NAME", "a field named \"with\" cannot hold a function", field.span, "value.with(...) is the struct update; rename the field"))
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
      return error(State.fail(here, st, "CHECK-REDEFINED-NAME", "duplicate variant \"" + variant.name + "\" in enum \"" + T.display_name(node.name) + "\"", variant.span))
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
  taken = cx.catalog.entries.has_key?(node.name) or cx.functions.has_key?(node.name) or cx.structs.has_key?(node.name) or cx.enums.has_key?(node.name)
  if taken
    return error(State.fail(cx, st, "CHECK-REDEFINED-NAME", "\"" + T.display_name(node.name) + "\" is already defined", node.span))
  end
  seen: Set[String] = Set.new([])
  params: List[T.Type] = []
  for param in node.params
    if seen.include?(param.name)
      return error(State.fail(cx, st, "CHECK-REDEFINED-NAME", "duplicate parameter \"" + param.name + "\"", param.span))
    end
    seen = seen.add(param.name)
    params = params.push(try Types.resolve_type(cx, st, param.type, false))
  end
  result = try Types.resolve_type(cx, st, node.result, true)
  return ok(cx.with(functions: cx.functions.put(node.name, State.Signature(params: params, result: result))))
end
