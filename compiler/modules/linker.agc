## The module linker: loads the root file and its imports (modules.agc) and rewrites them into one program
## (rewrite.agc).

import Ast from "../syntax/ast"
import Declarations from "declarations"
import Env from "link_env"
import Failure from "link_failure"
import Modules from "modules"
import Resolve from "resolve"
import Rewrite from "rewrite"

## One file of the linked program: its stored name (Module.name: the path from the root folder, which the bytecode
## keeps, or `key@version/path` for a file of a package), its source text (for the help of the checker), its
## declarations with linked names and without exports, in the order of the file. first_id and next_id bound the node
## ids of the file (its imports and exports count too, so the declarations leave gaps). aliases maps each import alias
## the file wrote to the key of the module it names, so a type of another file can be printed as the file writes it
## (`Models.User`, `agentica type-at`). parsed is the file as the parser gave it: the linker drops the `export` of a
## declaration and with it the `##` doc that sits on the export, so the docs of a file (`agentica type-at`) are read
## from here.
export struct LinkedModule
  key: String
  file: String
  name: String
  prefix: String
  first_id: Int
  next_id: Int
  text: String
  declarations: List[Ast.Decl]
  aliases: Map[String, String]
  parsed: Ast.Program
end

## A linked program: the root file as parsed (its id, span and module doc), the folder of the root file, the files with
## the root first, each file before the files its imports read, and ids, the number of node ids the checker must make
## room for: the ids of the parser, and as many again when a file declares a constant, because the linker gives the
## receiver of a rewritten NAME.method(...) the id of the call plus the number of ids of the program
## (Rewrite.rewrite_constant_member).
export struct Linked
  root: Ast.Program
  root_dir: String
  modules: List[LinkedModule]
  ids: Int
end

## The result of linking: the program, or the first failure.
export enum Linking
  Done(Linked)
  Failed(Failure.Failure)
end

## Links the file at path, with the std/ sources of settings.std and the environment of settings.env.
export def link_file(path: String, settings: Env.Settings) -> Linking
  return link_file_with(path, settings, Modules.no_parses())
end

## Like `link_file`, taking the trees of `parses` for the files whose text is the same (Modules.load_with).
export def link_file_with(path: String, settings: Env.Settings, parses: Modules.Parses) -> Linking
  loaded = Modules.load_with(path, settings, parses)
  if loaded.ok?
    return link_loaded(loaded.unwrap!, settings)
  end
  return Linking.Failed(Failure.unpack_failure(loaded.message))
end

## The program in the form the checker reads: the declarations of every file in one list, with the id, span and module
## doc of the root.
export def program(linked: Linked) -> Ast.Program
  declarations: List[Ast.Decl] = []
  for module in linked.modules
    declarations = declarations.concat(module.declarations)
  end
  return Ast.Program(
    id: linked.root.id,
    declarations: declarations,
    module_doc: linked.root.module_doc,
    span: linked.root.span,
  )
end

## Links files that were loaded (Modules.load_with): the second half of `link_file`.
export def link_loaded(loaded: Modules.Loaded, settings: Env.Settings) -> Linking
  files = rewrite_all(loaded, settings)
  if files.ok?
    root = loaded.modules[loaded.order[0]].program
    return Linking.Done(Linked(root: root, root_dir: loaded.root_dir, modules: files.unwrap!, ids: id_count(loaded)))
  end
  return Linking.Failed(Failure.unpack_failure(files.message))
end

# The ids of the parser end at the highest next_free_id of the files. The files are numbered one after the other in the
# order of loaded.order unless a walk kept some trees of an earlier one (Modules.Parses), which leaves gaps.
def parser_ids(loaded: Modules.Loaded) -> Int
  ids = 0
  for key in loaded.order
    next = Ast.next_free_id(loaded.modules[key].program)
    if next > ids
      ids = next
    end
  end
  return ids
end

def id_count(loaded: Modules.Loaded) -> Int
  for key in loaded.order
    if loaded.modules[key].names.values.any? do |kind| Declarations.constant?(kind) end
      return parser_ids(loaded) * 2
    end
  end
  return parser_ids(loaded)
end

def rewrite_all(loaded: Modules.Loaded, settings: Env.Settings) -> Result[List[LinkedModule]]
  out: List[LinkedModule] = []
  ids = parser_ids(loaded)
  for key in loaded.order
    module = loaded.modules[key]
    cx = Resolve.Context(
      settings: settings,
      modules: loaded.modules,
      me: module,
      visible: visible_structs(module, loaded.modules),
      ids: ids,
    )
    declarations = try Rewrite.rewrite_declarations(cx)
    out = out.push(
      LinkedModule(
        key: key,
        file: module.file,
        name: module.name,
        prefix: module.prefix,
        first_id: module.first_id,
        next_id: Ast.next_free_id(module.program),
        text: module.text,
        declarations: declarations,
        aliases: module.aliases,
        parsed: module.program,
      ),
    )
  end
  return ok(out)
end

# A file may update its own structs and the exported structs of the files it imports (the privacy rule of `.with`, the
# `visible` predicate as data). A file imported by name counts as imported, with all its exported
# structs: an alias import of it would allow them too.
def visible_structs(module: Modules.Module, modules: Map[String, Modules.Module]) -> List[String]
  names = structs_of(module.prefix, module.names)
  for target in module.aliases.values
    names = names.concat(structs_of(modules[target].prefix, modules[target].public))
  end
  for entry in module.named.values
    names = names.concat(structs_of(modules[entry.target].prefix, modules[entry.target].public))
  end
  return Set.new(names).to_a.sort
end

def structs_of(prefix: String, kinds: Map[String, Declarations.Kind]) -> List[String]
  return kinds.keys.filter do |name| Declarations.struct?(kinds[name]) end.map do |name| prefix + name end
end
