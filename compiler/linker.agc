## The module linker: loads the root file and its imports (modules.agc) and rewrites them into one program (rewrite.agc). This is link-program and load-program of src/modules.rkt.

import Ast from "ast"
import Declarations from "declarations"
import Env from "link_env"
import Failure from "link_failure"
import Modules from "modules"
import Resolve from "resolve"
import Rewrite from "rewrite"

## One file of the linked program: its source text (for the help of the checker), its declarations with linked names and without exports, in the order of the file. first_id and next_id bound the node ids of the file (its imports and exports count too, so the declarations leave gaps).
export struct LinkedModule
  key: String
  file: String
  prefix: String
  first_id: Int
  next_id: Int
  text: String
  declarations: List[Ast.Decl]
end

## A linked program: the root file as parsed (its id, span and module doc), the folder of the root file, the files with the root first, each file before the files its imports read, and ids, the number of node ids the checker must make room for: the ids of the parser, and as many again when a file declares a constant, because the linker gives the receiver of a rewritten NAME.method(...) the id of the call plus the number of ids of the program (Rewrite.rewrite_constant_member).
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

## Links the file at path, with the std/ sources of settings.stdlib and the environment of settings.env.
export def link_file(path: String, settings: Env.Settings) -> Linking
  linked = Modules.load(path, settings)
  if linked.ok?
    return finish(linked.unwrap!, settings)
  end
  return Linking.Failed(Failure.unpack_failure(linked.message))
end

## The program in the form the checker reads: the declarations of every file in one list, with the id, span and module doc of the root.
export def program(linked: Linked) -> Ast.Program
  declarations: List[Ast.Decl] = []
  for module in linked.modules
    declarations = declarations.concat(module.declarations)
  end
  return Ast.Program(id: linked.root.id, declarations: declarations, module_doc: linked.root.module_doc, span: linked.root.span)
end

def finish(loaded: Modules.Loaded, settings: Env.Settings) -> Linking
  files = rewrite_all(loaded, settings)
  if files.ok?
    root = loaded.modules[loaded.order[0]].program
    return Linking.Done(Linked(root: root, root_dir: loaded.root_dir, modules: files.unwrap!, ids: id_count(loaded)))
  end
  return Linking.Failed(Failure.unpack_failure(files.message))
end

# The files are numbered one after the other in the order of loaded.order, so the last one ends the ids of the parser.
def parser_ids(loaded: Modules.Loaded) -> Int
  return Ast.next_free_id(loaded.modules[loaded.order[loaded.order.size - 1]].program)
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
    cx = Resolve.Context(settings: settings, modules: loaded.modules, me: module, visible: visible_structs(module, loaded.modules), ids: ids)
    declarations = try Rewrite.rewrite_declarations(cx)
    out = out.push(LinkedModule(key: key, file: module.file, prefix: module.prefix, first_id: module.first_id, next_id: Ast.next_free_id(module.program), text: module.text, declarations: declarations))
  end
  return ok(out)
end

# A file may update its own structs and the exported structs of the files it imports (the privacy rule of `.with`, the `visible` predicate of src/modules.rkt as data). A file imported by name counts as imported, with all its exported structs: an alias import of it would allow them too.
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
