## Links the roots of a `symbol` query (docs/future/39-semantic-cli.md, 39.6): each root on its own, so a file that
## does not lex, parse or link is left out and listed, and the others still answer. The modules of all the roots are
## merged by key, in the order they were linked, so a file that several roots import is searched once.
##
## Each root is linked with `Linker.link_file`, which starts from empty tables; a root whose module an earlier root
## already linked is not linked again (its module is the same file, and its aliases belong to the module). That saves
## a link only when the importer comes first: a root that sorts before the files it imports is linked, and those are
## skipped. When the imported file sorts first (a chain where `f2` imports `f1`, `f3` imports `f2`), every root links
## its whole closure, so a folder costs at worst one link of the closure per root. The real fix is one link for all the
## roots (`Linker.link_programs` of docs/future/39-semantic-cli.md 39.8) or a cache kept between commands.

import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import Linker from "../modules/linker"
import Problems from "../diagnostics/problem"
import QueryFiles from "query_files"
import SymbolPaths from "symbol_paths"

## A root left out, with the name its answer gives it and the first problem it hit.
export struct Skipped
  file: String
  problem: Problems.Problem
end

## What linking the roots gave: the merged modules, with the aliases of the roots among them, and the roots left out.
export struct Linked
  modules: List[Linker.LinkedModule]
  skipped: List[Skipped]
end

## Links every root of `roots`.
export def link(roots: List[SymbolPaths.Root], settings: Env.Settings) -> Linked
  modules: List[Linker.LinkedModule] = []
  known: Map[String, Bool] = {}
  skipped: List[Skipped] = []
  for root in roots
    if !known.has_key?(root.key)
      case Linker.link_file(root.typed, settings)
        Linker.Linking.Done(linked) ->
          for module in linked.modules
            if !known.has_key?(module.key)
              modules = modules.push(module)
              known = known.put(module.key, true)
            end
          end
        Linker.Linking.Failed(failure) ->
          shown = QueryFiles.display(settings, root.key, true)
          skipped = skipped.push(Skipped(file: shown, problem: problem_of(failure, root)))
      end
    end
  end
  return Linked(modules: modules, skipped: skipped)
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
