## Links the roots of a `symbol` or `refs` query (docs/future/39-semantic-cli.md, 39.6 and 39.8) into one program with
## `Linker.link_programs`: a file that does not lex, parse or link is left out and listed, and the others still
## answer. A file that several roots reach is linked once, so a folder costs about one link of its files together.

import Ast from "../syntax/ast"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import Linker from "../modules/linker"
import Modules from "../modules/modules"
import Problems from "../diagnostics/problem"
import QueryFiles from "query_files"
import SymbolPaths from "symbol_paths"

## A root left out, with the name its answer gives it and the first problem it hit.
export struct Skipped
  file: String
  problem: Problems.Problem
end

## What linking the roots gave: the program of the roots that linked (Absent when none did), its modules in the order
## they were linked, with the roots among them, and the roots left out.
export struct Linked
  program: Ast.Optional[Linker.Linked]
  modules: List[Linker.LinkedModule]
  skipped: List[Skipped]
end

## Links every root of `roots`, taking the trees of `parses` for the files whose text is the same.
export def link(roots: List[SymbolPaths.Root], settings: Env.Settings, parses: Modules.Parses) -> Linked
  programs = Linker.link_programs(roots.map do |root: SymbolPaths.Root| root.typed end, settings, parses)
  skipped = programs.skipped.map do |left: Linker.Left|
    root = rooted(roots, left.root)
    Skipped(file: QueryFiles.display(settings, root.key, true), problem: problem_of(left.failure, root))
  end
  modules: List[Linker.LinkedModule] = []
  case programs.linked
    Ast.Optional.Present(together) -> modules = together.modules
    Ast.Optional.Absent -> modules = modules
  end
  return Linked(program: programs.linked, modules: modules, skipped: skipped)
end

# The root that was typed as `typed`.
def rooted(roots: List[SymbolPaths.Root], typed: String) -> SymbolPaths.Root
  named = roots.filter do |root: SymbolPaths.Root| root.typed == typed end
  return named[0]
end

# The problem of a failure, as `check` prints it. A problem in the root file names it as it was typed (the linker knows
# it by its canonical path), and one in an imported file by its canonical path.
def problem_of(failure: Failure.Failure, root: SymbolPaths.Root) -> Problems.Problem
  diagnostic = failure.diagnostic
  problem = Problems.problem(failure.file, "", diagnostic.code, diagnostic.message, diagnostic.span, diagnostic.help)
  if failure.file == root.typed or failure.file == root.key
    return problem.with(key_path: failure.key_path, file: root.typed)
  end
  return problem.with(key_path: failure.key_path)
end
