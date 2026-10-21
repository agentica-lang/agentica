## `agentica doc` as a stage: the text of one module in, its documented API out, or the first lexer or parser
## diagnostic. It lexes and parses only (docs/future/32-doc-comments.md, 32.5): it does not link the module,
## resolve its imports or check it, so a missing dependency cannot make it fail. The text is read by the caller
## (app/cli_doc.agc), which holds the Workspace.

import Ast from "../syntax/ast"
import Diag from "../diagnostics/diagnostic"
import Lexer from "../syntax/lexer"
import Model from "doc_model"
import Parser from "../syntax/parser"

## The parsed program of the module in `text`, or the first lexer or parser diagnostic. `agentica outline` shares it.
export def parse(text: String) -> Diag.Outcome[Ast.Program]
  case Lexer.lex(text)
    Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(tokens) -> return Parser.parse(tokens, 0)
  end
end

## The exported API of the module in `text`, or the first lexer or parser diagnostic.
export def of_text(text: String) -> Diag.Outcome[Model.Module]
  case parse(text)
    Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(program) -> return Diag.Outcome.Done(Model.of_program(program, text))
  end
end
