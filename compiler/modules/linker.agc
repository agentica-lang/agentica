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
## from here. named maps each local name of an import list (`create` of `import {make as create} from "models"`) to
## the linked name of what it stands for (`@2::make`), so a query can tell which declaration an imported name selects.
## watched are the files of its package that its extern functions may open (the bytecode cache watches them).
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
  named: Map[String, String]
  parsed: Ast.Program
  watched: List[String]
end

## A linked program: the root file as parsed (its id, span and module doc), the folder of the root file, the files with
## the root first, each file before the files its imports read, and ids, the number of node ids the checker must make
## room for: the ids of the parser, and as many again when a file declares a constant, because the linker gives the
## receiver of a rewritten NAME.method(...) the id of the call plus the number of ids of the program
## (Rewrite.rewrite_constant_member). receivers is the first of those extra ids (the highest id of the parser), or -1
## when no file declares a constant. roots are the keys of the modules that are roots: the first file for `link_file`,
## each root that linked for `link_programs`. The checker checks the `main` of those and no other.
export struct Linked
  root: Ast.Program
  root_dir: String
  modules: List[LinkedModule]
  ids: Int
  receivers: Int
  roots: List[String]
end

## The result of linking: the program, or the first failure.
export enum Linking
  Done(Linked)
  Failed(Failure.Failure)
end

## A root that link_programs left out: the path as it was given, and the first failure of its own file or of a file it
## reaches.
export struct Left
  root: String
  failure: Failure.Failure
end

## The result of linking several roots: the program of the roots that linked (Absent when none did) and the roots that
## were left out, in the order given.
export struct Programs
  linked: Ast.Optional[Linked]
  skipped: List[Left]
end

# What link_programs knows while it admits the roots one after the other: the modules kept, in order, and by key; the
# modules rewritten so far (a root that fails may leave some, which a later root reuses); and the modules whose
# rewrite failed, with the failure.
struct Pool
  kept: List[LinkedModule]
  held: Map[String, Bool]
  made: Map[String, LinkedModule]
  failed: Map[String, Failure.Failure]
end

# A pool after one root, and why the root was left out (Absent when it was kept).
struct Admission
  pool: Pool
  failure: Ast.Optional[Failure.Failure]
end

## Links the file at path, with the std/ sources of settings.std and the environment of settings.env.
export def link_file(path: String, settings: Env.Settings) -> Linking
  return link_file_with(path, settings, Modules.no_parses())
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

## Links several roots into one program with shared tables (docs/future/39-semantic-cli.md, 39.8): a module that two
## roots reach is linked once, and every module, the roots too, has the prefix "@N::", so two roots may declare `main`.
## A root is a transaction. If its own file or a file it reaches does not lex, parse or link, the root is left out and
## none of its modules stays, but the modules an earlier root linked do; a module whose rewrite failed is remembered,
## so a later root that reaches it is left out with the same failure. The modules are in the order of the roots, and
## those of one root in the order of its imports, as `link_file` gives them, so a module that two roots reach comes
## with the first. The first failure of a root is the one `link_file` gives it.
export def link_programs(roots: List[String], settings: Env.Settings, parses: Modules.Parses) -> Programs
  many = Modules.load_roots(roots, settings, parses)
  loaded = many.loaded
  ids = 0
  if loaded.order.size > 0
    ids = parser_ids(loaded)
  end
  pool = Pool(kept: [], held: {}, made: {}, failed: {})
  skipped: List[Left] = []
  kept: List[Modules.Entry] = []
  for entry in many.entries
    case entry.failure
      Ast.Optional.Present(failure) -> skipped = skipped.push(Left(root: entry.typed, failure: failure))
      Ast.Optional.Absent ->
        admitted = admit(loaded, settings, ids, pool, entry.key)
        pool = admitted.pool
        case admitted.failure
          Ast.Optional.Present(failure) -> skipped = skipped.push(Left(root: entry.typed, failure: failure))
          Ast.Optional.Absent -> kept = kept.push(entry)
        end
    end
  end
  if kept.size == 0
    return Programs(linked: Ast.Optional.Absent, skipped: skipped)
  end
  together = Linked(
    root: loaded.modules[kept[0].key].program,
    root_dir: kept[0].root_dir,
    modules: pool.kept,
    ids: id_count(loaded),
    receivers: receivers_at(loaded),
    roots: kept.map do |entry: Modules.Entry| entry.key end,
  )
  return Programs(linked: Ast.Optional.Present(together), skipped: skipped)
end

## Links files that were loaded (Modules.load_with): the second half of `link_file`.
export def link_loaded(loaded: Modules.Loaded, settings: Env.Settings) -> Linking
  files = rewrite_all(loaded, settings)
  if files.ok?
    root = loaded.modules[loaded.order[0]].program
    return Linking.Done(
      Linked(
        root: root,
        root_dir: loaded.root_dir,
        modules: files.unwrap!,
        ids: id_count(loaded),
        receivers: receivers_at(loaded),
        roots: [loaded.order[0]],
      ),
    )
  end
  return Linking.Failed(Failure.unpack_failure(files.message))
end

# The root `key` and the files it reaches, in the order `link_file` lists them: the file, then the files of its first
# import with theirs, then the second, and so on, each once.
def reached(loaded: Modules.Loaded, key: String) -> List[String]
  order: List[String] = []
  seen: Map[String, Bool] = {}
  pending = [key]
  while pending.size > 0
    here = pending[pending.size - 1]
    pending = pending.take(pending.size - 1)
    if seen.has_key?(here)
      next
    end
    seen = seen.put(here, true)
    order = order.push(here)
    for imported in loaded.modules[here].imports.reverse
      if !seen.has_key?(imported)
        pending = pending.push(imported)
      end
    end
  end
  return order
end

# Rewrites the files of the root `key` that the pool does not hold. When every one rewrites, they join the pool; the
# first that does not is the failure of the root, and the pool keeps what it learned (the files rewritten, the
# failure).
def admit(loaded: Modules.Loaded, settings: Env.Settings, ids: Int, pool: Pool, key: String) -> Admission
  fresh: List[LinkedModule] = []
  made = pool.made
  failed = pool.failed
  for file in reached(loaded, key)
    if pool.held.has_key?(file)
      next
    elsif failed.has_key?(file)
      return Admission(pool: pool.with(made: made), failure: Ast.Optional.Present(failed[file]))
    elsif made.has_key?(file)
      fresh = fresh.push(made[file])
    else
      rewritten = rewrite_module(loaded, settings, ids, file)
      if !rewritten.ok?
        failure = Failure.unpack_failure(rewritten.message)
        return Admission(
          pool: pool.with(made: made, failed: failed.put(file, failure)),
          failure: Ast.Optional.Present(failure),
        )
      end
      made = made.put(file, rewritten.unwrap!)
      fresh = fresh.push(rewritten.unwrap!)
    end
  end
  held = pool.held
  for module in fresh
    held = held.put(module.key, true)
  end
  return Admission(
    pool: Pool(kept: pool.kept.concat(fresh), held: held, made: made, failed: failed),
    failure: Ast.Optional.Absent,
  )
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

# Where the receivers of rewritten constant members start (the room id_count made), or -1 when there is none.
def receivers_at(loaded: Modules.Loaded) -> Int
  if id_count(loaded) > parser_ids(loaded)
    return parser_ids(loaded)
  end
  return -1
end

def rewrite_all(loaded: Modules.Loaded, settings: Env.Settings) -> Result[List[LinkedModule]]
  out: List[LinkedModule] = []
  ids = parser_ids(loaded)
  for key in loaded.order
    module = try rewrite_module(loaded, settings, ids, key)
    out = out.push(module)
  end
  return ok(out)
end

# The file `key` of `loaded` with its names rewritten. `ids` is the number of node ids of the parser, which the
# receivers of rewritten constant members count from.
def rewrite_module(loaded: Modules.Loaded, settings: Env.Settings, ids: Int, key: String) -> Result[LinkedModule]
  module = loaded.modules[key]
  cx = Resolve.Context(
    settings: settings,
    modules: loaded.modules,
    me: module,
    visible: visible_structs(module, loaded.modules),
    ids: ids,
  )
  declarations = try Rewrite.rewrite_declarations(cx)
  return ok(
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
      named: linked_names(module, loaded.modules),
      parsed: module.program,
      watched: module.origin.watched,
    ),
  )
end

# Each local name of the import lists of `module` and the linked name it stands for.
def linked_names(module: Modules.Module, modules: Map[String, Modules.Module]) -> Map[String, String]
  out: Map[String, String] = {}
  for local in module.named.keys
    entry = module.named[local]
    out = out.put(local, modules[entry.target].prefix + entry.name)
  end
  return out
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

# Like `link_file`, with the trees of `parses` for the files whose text is the same (Modules.load_with).
def link_file_with(path: String, settings: Env.Settings, parses: Modules.Parses) -> Linking
  loaded = Modules.load_with(path, settings, parses)
  if loaded.ok?
    return link_loaded(loaded.unwrap!, settings)
  end
  return Linking.Failed(Failure.unpack_failure(loaded.message))
end
