## The original declarations behind the re-exports of a file (`export Url.parse`), for `agentica doc` and `agentica
## outline`. Both only parse the file, but a re-export names a declaration of another file, so the file is linked when
## it re-exports something. A file that does not link lists no re-export: its imports may be missing, and the two
## commands never fail for that.

import Declarations from "../modules/declarations"
import Env from "../modules/link_env"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import T from "../syntax/types"
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
# own name. The items of a file are built once, the first time a name needs the file, and each name is a lookup.
def of_linked(linked: Linker.Linked) -> Map[String, Model.Item]
  files: Map[String, Linker.LinkedModule] = {}
  for module in linked.modules
    if module.prefix != ""
      files = files.put(module.prefix, module)
    end
  end

  built: Map[String, Map[String, Model.Item]] = {}
  origins: Map[String, Model.Item] = {}
  root = linked.modules[0]
  for name in root.reexported.keys
    target = root.reexported[name]
    own = T.display_name(target)
    prefix = target.slice(0, target.length - own.length)
    if !files.has_key?(prefix)
      next
    end

    if !built.has_key?(prefix)
      built = built.put(prefix, items_by_name(files[prefix]))
    end

    found = built[prefix].get(own)
    if found.ok?
      origins = origins.put(name, found.unwrap!)
    end
  end

  return origins
end

# The declarations of a file by their own name.
def items_by_name(module: Linker.LinkedModule) -> Map[String, Model.Item]
  items: Map[String, Model.Item] = {}
  for item in Model.declared(module.parsed, module.text)
    items = items.put(item.name, item)
  end

  return items
end
