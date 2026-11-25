## The rules that read a top-level declaration: a `##` doc on code that is not exported, and a type that it writes
## with a Result in a Result or an Optional in an Optional.

import Problems from "../diagnostics/problem"
import Ast from "../syntax/ast"
import Rules from "rules"

## The suggestions for `decl`: LINT-NESTED-WRAPPER for the types it writes, and LINT-PRIVATE-DOC. An exported
## declaration is public, so its doc is right; so is the doc of an extern function or a C struct, which the parser
## makes from a block.
def suggestions(file: String, decl: Ast.Decl) -> List[Problems.Problem]
  case decl
    Ast.Decl.Export(node) -> nested_wrappers(file, node.declaration)
    _ -> nested_wrappers(file, decl).concat(private_docs(file, decl))
  end
end

private

WRAPPERS = Set.new(["Result", "Optional"])

# Only the types that a signature, a struct field or an alias writes: the type of a local or of a lambda is not
# judged, and a Result in a Result that comes from instantiating a generic (`task.await`, `list.first`) is no written
# type at all.
def nested_wrappers(file: String, decl: Ast.Decl) -> List[Problems.Problem]
  case decl
    Ast.Decl.Function(node) ->
      written = node.params.map do |param: Ast.Param| param.type end
      written.concat([node.result]).flat_map do |type: Ast.TypeRef| nested_in(file, type, "") end
    Ast.Decl.Struct(node) -> node.fields.flat_map do |field: Ast.FieldDecl| nested_in(file, field.type, "") end
    Ast.Decl.TypeAlias(node) -> nested_in(file, node.target, "")
    _ -> []
  end
end

# The outer type of each Result[Result[T]] and Optional[Optional[T]] inside `type`, once for each run of the same
# wrapper (`parent` is the name of the type around this one).
def nested_in(file: String, type: Ast.TypeRef, parent: String) -> List[Problems.Problem]
  found: List[Problems.Problem] = []
  if WRAPPERS.include?(type.name) and type.name != parent and type.args.size == 1 and type.args[0].name == type.name
    rule = Rules.NESTED_WRAPPER.with(message: wrapper_message(type.name), help: wrapper_help(type.name))
    found = [Rules.at(file, rule, type.span)]
  end

  found.concat(type.args.flat_map do |arg: Ast.TypeRef| nested_in(file, arg, type.name) end)
end

def private_docs(file: String, decl: Ast.Decl) -> List[Problems.Problem]
  case decl
    Ast.Decl.Function(node) ->
      return [Rules.at(file, Rules.PRIVATE_DOC, node.name_span)] if node.doc.some? and node.native.none?

      []
    Ast.Decl.Struct(node) ->
      if node.doc.some? and node.layout == "" and node.record_of == ""
        return [Rules.at(file, Rules.PRIVATE_DOC, node.name_span)]
      end

      []
    Ast.Decl.Enum(node) ->
      return [Rules.at(file, Rules.PRIVATE_DOC, node.name_span)] if node.doc.some?

      []
    _ -> []
  end
end

def wrapper_message(name: String) -> String = "this type is a #{name} of a #{name}"

def wrapper_help(name: String) -> String
  case name
    "Result" ->
      (
        "flatten it with `try` on the inner value so one Result is left, or give the inner failure an error of its " +
        "own; keep both layers when the outer error and the inner error mean different things"
      )
    _ ->
      (
        "use one Optional; keep both layers only when a missing value and a present but empty one mean different " +
        "things"
      )
  end
end
