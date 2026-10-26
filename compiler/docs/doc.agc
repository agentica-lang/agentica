## `agentica doc` as a stage: the text of one module in, its documented API out, or the first lexer or parser
## diagnostic. It lexes and parses only (docs/future/32-doc-comments.md, 32.5): it does not resolve the imports or
## check the module, so a missing dependency cannot make it fail; the exception is a module that re-exports a name,
## which is linked to find the original declaration (doc_origins.agc). The text is read by the caller
## (app/cli_doc.agc), which holds the Workspace.

import Diag from "../diagnostics/diagnostic"
import Env from "../modules/link_env"
import Ast from "../syntax/ast"
import Lexer from "../syntax/lexer"
import Parser from "../syntax/parser"
import Model from "doc_model"
import Origins from "doc_origins"

## The parsed program of the module in `text`, or the first lexer or parser diagnostic. `agentica outline` shares it.
export def parse(text: String) -> Diag.Outcome[Ast.Program]
  case Lexer.lex(text)
    Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(tokens) -> return Parser.parse(tokens, 0)
  end
end

## The exported API of the module in `text`, the text of the file at `path`, or the first lexer or parser diagnostic.
## Only a module that re-exports something reads its imports (doc_origins.agc).
export def of_file(settings: Env.Settings, path: String, text: String) -> Diag.Outcome[Model.Module]
  case parse(text)
    Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(program) ->
      return Diag.Outcome.Done(Model.of_program(program, text, Origins.of_file(settings, path, program)))
  end
end
