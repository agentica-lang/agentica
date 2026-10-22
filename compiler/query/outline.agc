## `agentica outline` as a stage (docs/future/39-semantic-cli.md, 39.3): the text of one file in, its imports and
## top-level declarations out, or the first lexer or parser diagnostic. The file is only lexed and parsed (39.6), so a
## missing import cannot make it fail. The declarations are the items of `agentica doc` (docs/doc_model.agc), private
## ones included, so the signatures, docs and summaries of the two commands cannot drift.

import Diag from "../diagnostics/diagnostic"
import Docs from "../docs/doc"
import Model from "../docs/doc_model"
import Ast from "../syntax/ast"

## What a file declares: its doc, its imports and its other declarations, each in source order.
export struct Outline
  doc: Ast.Optional[String]
  imports: List[Ast.ImportDecl]
  items: List[Model.Item]
end

## The outline of the file whose text is `text`, or the first lexer or parser diagnostic.
export def of_text(text: String) -> Diag.Outcome[Outline]
  case Docs.parse(text)
    Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(program) ->
      return Diag.Outcome.Done(
        Outline(
          doc: Model.cleaned(program.module_doc),
          imports: imports_of(program),
          items: Model.declared(program, text),
        ),
      )
  end
end

# The import declarations, in source order. An import is a top-level declaration like the others in the tree.
def imports_of(program: Ast.Program) -> List[Ast.ImportDecl]
  imports: List[Ast.ImportDecl] = []
  for declaration in program.declarations
    case declaration
      Ast.Decl.Import(node) -> imports = imports.push(node)
      Ast.Decl.Export(_) -> imports = imports
      Ast.Decl.Function(_) -> imports = imports
      Ast.Decl.Struct(_) -> imports = imports
      Ast.Decl.Enum(_) -> imports = imports
      Ast.Decl.TypeAlias(_) -> imports = imports
      Ast.Decl.Resource(_) -> imports = imports
      Ast.Decl.Constant(_) -> imports = imports
    end
  end
  return imports
end
