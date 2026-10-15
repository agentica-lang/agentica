## The module linker: loads the root file and its imports (modules.agc) and rewrites them into one program (rewrite.agc). This is link-program and load-program of src/modules.rkt.

import "ast" as Ast
import "link_env" as Env
import "link_failure" as Failure
import "modules" as Modules
import "resolve" as Resolve
import "rewrite" as Rewrite

## One file of the linked program: its declarations with linked names and without exports, in the order of the file. first_id and next_id bound the node ids of the file (its imports and exports count too, so the declarations leave gaps).
export struct LinkedModule
  key: String
  file: String
  prefix: String
  first_id: Int
  next_id: Int
  declarations: List[Ast.Decl]
end

## A linked program: the root file as parsed (its id, span and module doc), the folder of the root file, and the files with the root first, each file before the files its imports read.
export struct Linked
  root: Ast.Program
  root_dir: String
  modules: List[LinkedModule]
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
    return Linking.Done(Linked(root: root, root_dir: loaded.root_dir, modules: files.unwrap!))
  end
  return Linking.Failed(Failure.unpack_failure(files.message))
end

def rewrite_all(loaded: Modules.Loaded, settings: Env.Settings) -> Result[List[LinkedModule]]
  out: List[LinkedModule] = []
  for key in loaded.order
    module = loaded.modules[key]
    cx = Resolve.Context(settings: settings, modules: loaded.modules, me: module, visible: visible_structs(module, loaded.modules))
    declarations = try Rewrite.rewrite_declarations(cx)
    out = out.push(LinkedModule(key: key, file: module.file, prefix: module.prefix, first_id: module.first_id, next_id: Ast.next_free_id(module.program), declarations: declarations))
  end
  return ok(out)
end

# A file may update its own structs and the exported structs of the files it imports (the privacy rule of `.with`, the `visible` predicate of src/modules.rkt as data).
def visible_structs(module: Modules.Module, modules: Map[String, Modules.Module]) -> List[String]
  names = structs_of(module.prefix, module.names)
  for target in module.aliases.values
    names = names.concat(structs_of(modules[target].prefix, modules[target].public))
  end
  return Set.new(names).to_a.sort
end

def structs_of(prefix: String, kinds: Map[String, String]) -> List[String]
  return kinds.keys.filter do |name| kinds[name] == "struct" end.map do |name| prefix + name end
end
