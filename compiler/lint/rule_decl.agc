## The rule that reads a top-level declaration: a `##` doc on code that is not exported.

import Problems from "../diagnostics/problem"
import Ast from "../syntax/ast"
import Rules from "rules"

## The suggestions for `decl`. An exported declaration is public, so its doc is right; so is the doc of an extern
## function or a C struct, which the parser makes from a block.
def suggestions(file: String, decl: Ast.Decl) -> List[Problems.Problem]
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
