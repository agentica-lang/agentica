## The original declarations behind the re-exports of a file (`export Url.parse`), for `agentica doc` and `agentica
## outline`. Both only parse the file, but a re-export names a declaration of another file, so the file is linked when
## it re-exports something. A file that does not link lists no re-export: its imports may be missing, and the two
## commands never fail for that.

import Declarations from "../modules/declarations"
import Env from "../modules/link_env"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import Model from "doc_model"

## The item of the original declaration of each name that `program`, the parse of the file at `path`, re-exports. It is
## empty for a file that re-exports nothing, and for one that does not link.
export def of_file(settings: Env.Settings, path: String, program: Ast.Program) -> Map[String, Model.Item]
  if Declarations.reexports_of(program.declarations).size == 0
    return {}
  end

  case Linker.link_file(path, settings)
    Linker.Linking.Done(linked) -> return of_linked(linked)
    Linker.Linking.Failed(_) -> return {}
  end
end

# The root file comes first in a linked program. The linked name of the original is its file's "@N::" prefix and its
# own name, so the file is the one whose prefix starts that name.
def of_linked(linked: Linker.Linked) -> Map[String, Model.Item]
  origins: Map[String, Model.Item] = {}
  root = linked.modules[0]
  for name in root.reexported.keys
    target = root.reexported[name]
    for module in linked.modules
      if module.prefix != "" and target.starts_with?(module.prefix)
        own = target.slice(module.prefix.length, target.length - module.prefix.length)
        for item in Model.declared(module.parsed, module.text)
          if item.name == own
            origins = origins.put(name, item)
          end
        end
      end
    end
  end

  return origins
end
