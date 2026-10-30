## The one-line signatures of `agentica doc` (docs/future/32-doc-comments.md, 32.5), printed from the syntax tree. A
## type is printed as written, so an import alias such as `Models.User` stays as it is. The function form is the one of
## `Builtins.form_signature` (catalog/builtins.agc): `add(a: Int, b: Int) -> Int`.
##
## Types nest as deep as the parser allows, so `type_text` walks them with a stack of pieces and not by recursion.

import Ast from "../syntax/ast"

# One thing still to print: a type, or the text between types.
enum Piece
  Node(Ast.TypeRef)
  Text(String)
end

## The type as written: `List[Int]`, `Models.User`, `Fn[Int, String]`.
export def type_text(type: Ast.TypeRef) -> String
  work = [Piece.Node(type)]
  parts: List[String] = []
  while work.size > 0
    last = work.size - 1
    piece = work[last]
    work = work.take(last)
    case piece
      Piece.Text(text) -> parts = parts.push(text)
      Piece.Node(node) ->
        parts = parts.push(node.name)
        if node.args.size > 0
          parts = parts.push("[")
          work = work.concat(closing(node.args))
        end
    end
  end

  return parts.join("")
end

## `name(a: Int, b: Int = 2) -> Int`, or `name[T](a: T) -> T` for a generic function. `text` is the source of the
## module: a default value is printed as written there.
export def function_text(declaration: Ast.FunctionDecl, text: String) -> String
  parameters = declaration.params.map do |parameter: Ast.Param| parameter_text(parameter, text) end
  names = parameters_text(declaration.type_parameters)
  return "#{declaration.name}#{names}(#{parameters.join(", ")}) -> #{type_text(declaration.result)}"
end

## `callback Name(a: Int, p: C.Pointer) -> Int`: a callback of an extern block, with the Agentica types its function
## takes and returns.
export def callback_text(name: String, callback: Ast.Callback) -> String
  parameters = callback.params.map do |parameter: Ast.Param| "#{parameter.name}: #{type_text(parameter.type)}" end
  return "callback #{name}(#{parameters.join(", ")}) -> #{type_text(callback.result)}"
end

## `struct Name` or `struct Name[T, U]`.
export def struct_text(declaration: Ast.StructDecl) -> String
  return "struct #{declaration.name}#{parameters_text(declaration.type_parameters)}"
end

## `enum Name` or `enum Name[T, U]`.
export def enum_text(declaration: Ast.EnumDecl) -> String
  return "enum #{declaration.name}#{parameters_text(declaration.type_parameters)}"
end

## `Name` or `Name(Int, String)`: a variant with the types of its payload, as written.
export def variant_text(name: String, payload: List[String]) -> String
  if payload.size == 0
    return name
  end

  return "#{name}(#{payload.join(", ")})"
end

## `type Name = Target` or `type Name[T] = Target`.
export def alias_text(declaration: Ast.TypeAliasDecl) -> String
  names = parameters_text(declaration.type_parameters)
  return "type #{declaration.name}#{names} = #{type_text(declaration.target)}"
end

## `NAME: Type`, or `NAME` when the constant has no written type.
export def constant_text(declaration: Ast.ConstDecl) -> String
  case declaration.type
    some(type) -> return "#{declaration.name}: #{type_text(type)}"
    none -> return declaration.name
  end
end

## The source text of the default value of a parameter or a struct field, or absent when it has none. A span ends
## after its last character, so the slice is the expression exactly as written.
export def default_text(default: Optional[Ast.Expr], text: String) -> Optional[String]
  case default
    none -> return none
    some(value) ->
      span = Ast.expr_span(value)
      return some(text.slice(span.start.offset, span.stop.offset - span.start.offset))
  end
end

# The pieces after an opening "[", in the order the stack gives them back: the first argument is the last one pushed,
# so it is printed first and the "]" comes out after the last argument.
def closing(args: List[Ast.TypeRef]) -> List[Piece]
  pieces: List[Piece] = [Piece.Text("]")]
  at = args.size - 1
  while at >= 0
    pieces = pieces.push(Piece.Node(args[at]))
    if at > 0
      pieces = pieces.push(Piece.Text(", "))
    end

    at -= 1
  end

  return pieces
end

def parameter_text(parameter: Ast.Param, text: String) -> String
  typed = "#{parameter.name}: #{type_text(parameter.type)}"
  case default_text(parameter.default, text)
    some(written) -> return "#{typed} = #{written}"
    none -> return typed
  end
end

# `[T, U]` for the type parameters of an enum or an alias, nothing for none.
def parameters_text(names: List[String]) -> String
  if names.size == 0
    return ""
  end

  return "[#{names.join(", ")}]"
end
