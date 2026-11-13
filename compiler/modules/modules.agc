## The module loader: starting at the root file, reads, lexes and parses every file the imports reach, once, and checks
## each one. This is the first half of linking; rewrite.agc is the second.
##
## The walk is a loop over an explicit stack of files that still have imports to read, so a long chain of imports uses
## no VM call depth. Files are met in a fixed order (a file is read at its import, before the imports
## after it), so the first failure is the same, and so are the node ids: every file is parsed from the next free id of
## the file read before it (parse, Ast.next_free_id).
##
## A client that walks the same program again and again (analysis/cache.agc) hands `load_with` the files it parsed
## earlier. A file whose text is the same is not parsed again: it keeps its tree and its ids, and a file that is parsed
## gets ids above every id the earlier files hold, so the ids of one walk have gaps and the files are not in the order
## of their ids. Nothing but the checker's tables reads a node id, so the program means the same.

import Builtins from "../catalog/builtins"
import {BARE_NAMES, ENUMS, OPAQUE_TYPES, RECORDS, RESERVED, STD_ONLY} from "../catalog/builtins"
import Diag from "../diagnostics/diagnostic"
import Packages from "../packages/package_import"
import PackageCache from "../packages/package_cache"
import Project from "../packages/project"
import Ast from "../syntax/ast"
import Lexer from "../syntax/lexer"
import Parser from "../syntax/parser"
import Source from "../syntax/source"
import SourceFile from "../syntax/source_file"
import T from "../syntax/types"
import CheckCache from "check_cache"
import Declarations from "declarations"
import ImportHelp from "import_help"
import Paths from "import_path"
import Env from "link_env"
import Failure from "link_failure"
import Resolve from "resolve_import"
import TestMain from "test_main"
import TypeCode from "type_code"
import Workspace from "workspace"

## The target of a re-export of a builtin type (`export LogRegistry.Event` in std/): no module has this key, and the
## name of the origin is the builtin's own (LogRegistry.Event).
BUILTIN = ""

## A name bound by import {Name} from "path" (or {Name as Local}): the key of the module that exports it and the
## exported name.
struct Named
  target: String
  name: String
end

## A file of the program once it is loaded. named maps each local name of an import list to what it names. name is the
## path the file is stored under (Paths.stored_name, or `pkg/name@version/path` for a file of a package), and origin
## the package it belongs to. reexports maps each name the file re-exports (`export Url.parse`) to the module that
## declares it and its name there: a chain is already followed, so the key is that of the original declaration, and
## `public` holds the name too, with the kind of the original. imports lists the keys of the files it imports, in the
## order of its import lines. The last eight fields are for the cache of checked modules (check_cache.agc) and are
## empty or false for a walk that does not use it, and for the root file: digest is the SHA-256 of the text, verified
## the tree digest that the cache's entry for this text vouches for, styled whether the entry says the text follows the
## style rule blank_line_after_end, and held the types of its constants (as type_code.agc writes them), stubbed whether
## program is the parse of the stub of that entry rather than of the text, tree the tree digest of this walk, and clean
## whether the two are the same and the entry types every constant, so the bodies and constants need no check:
## constants then has the type of each constant by its linked name. tested says that the file was read as the root of a
## test file (Settings.test_file), so its tree may hold the `main` of its test functions (test_main.agc). block is the
## name of the module block this module is (`enter_block`), "" for a file.
struct Module
  key: String
  file: String
  name: String
  origin: Packages.Origin
  prefix: String
  first_id: Int
  text: String
  program: Ast.Program
  names: Map[String, Declarations.Kind]
  public: Map[String, Declarations.Kind]
  aliases: Map[String, String]
  named: Map[String, Named]
  reexports: Map[String, Named]
  imports: List[String]
  digest: String
  verified: String
  styled: Bool
  held: Map[String, String]
  stubbed: Bool
  tree: String
  clean: Bool
  constants: Map[String, T.Type]
  tested: Bool
  block: String
end

## Every module of a program. order lists the keys with the root first, each file before the files its imports read; a
## file imported twice appears once. root_dir is the folder of the root file. parsed is the number of files that this
## walk lexed and parsed (stubs included); the others came from the Kept files it was given. stubs counts the files
## parsed from a stub.
struct Loaded
  order: List[String]
  modules: Map[String, Module]
  root_dir: String
  parsed: Int
  stubs: Int
end

## A file parsed by an earlier walk: its text, the first id of its tree, the tree, and whether it was read as the root
## of a test file (Module.tested). It can stand for the file in a later walk while the file has this text and is read
## the same way.
struct Kept
  text: String
  first_id: Int
  program: Ast.Program
  tested: Bool
end

## The files that a walk may take instead of parsing, by key, and top, an id above every id of those files (the ranges
## of the files in `kept` must not overlap). A file that has to be parsed gets ids from top on.
struct Parses
  kept: Map[String, Kept]
  top: Int
end

## One root of load_roots: the path as it was given, the key of its file, the folder of the root and, when it did not
## load, why (a packed failure read back, link_failure.agc).
struct Entry
  typed: String
  key: String
  root_dir: String
  failure: Optional[Failure.Failure]
end

## What load_roots gave: every module of the roots that loaded, and one Entry for each root, in the order given. The
## modules of a root that failed are not in `loaded`.
struct Roots
  loaded: Loaded
  entries: List[Entry]
end

## The kind of `name` in `module`: an export (a re-export included), or else a name that the file declares. A module
## block (`module_blocks`) reads the private names of its file through the `named` table, which points at the file.
def kind_in(module: Module, name: String) -> Declarations.Kind
  return module.public[name] if module.public.has_key?(name)

  module.names[name]
end

## The key of the module block `name` of the file `key`: the module that the linker makes of the block.
def block_key(key: String, name: String) -> String = "#{key}##{name}"

## The key of the module block that `module` exports as `name`, its own or one it re-exports, or "" when `name` is no
## exported module block.
def exported_block(module: Module, name: String) -> String
  return "" if !module.public.has_key?(name) or !Declarations.module?(module.public[name])

  return block_key(module.reexports[name].target, module.reexports[name].name) if module.reexports.has_key?(name)

  block_key(module.key, name)
end

## Parses nothing again: the files are numbered one after the other from 0.
def no_parses() -> Parses = Parses(kept: {}, top: 0)

## The name in the linked program of the export `name` of `module`: with the prefix of the file that declares it, which
## is another file when the module re-exports the name.
def linked_name(modules: Map[String, Module], module: Module, name: String) -> String
  if module.reexports.has_key?(name)
    origin = module.reexports[name]
    return origin.name if origin.target == BUILTIN

    return modules[origin.target].prefix + origin.name
  end

  module.prefix + name
end

## The help for a std-only family (STD_ONLY) named outside std/: the std module to import in its place.
def std_only_help(family: String) -> String
  wrapper = STD_ONLY[family]
  "#{family} is internal to #{wrapper[0]}; use import #{wrapper[1]} from \"#{wrapper[0]}\""
end

## The help of CHECK-IMPORT-NAME for `member`, which the module `target` does not export. A name it declares is private
## there: the help says to move it above `private`, and for a std/ module or a package, which the user does not edit,
## only that it is private. A name that a file only imports gets the re-export that passes it on. Any other name gets
## the did-you-mean over the exports.
def import_name_help(modules: Map[String, Module], target: Module, member: String) -> Diag.Help
  place = "\"#{target.name}\""
  if target.block != ""
    place = "module #{target.block} of \"#{target.name}\""
  end

  library = target.origin.library or target.origin.package != ""
  if target.names.has_key?(member)
    return Diag.Help.Hint("#{member} is private in #{place}") if library

    return Diag.Help.Hint("#{member} is private in #{place}: move it above private there")
  end

  if target.block == "" and block_holding(modules, target, member) != ""
    block = block_holding(modules, target, member)
    return Diag.Help.Hint("#{member} is in module #{block} of #{place}: write #{block}.#{member} after the alias")
  end

  imported = target.block == "" and imported_alias(modules, target, member) != ""
  if imported and library
    return Diag.Help.Hint("#{member} is imported by #{place}, which does not re-export it")
  elsif imported
    alias = imported_alias(modules, target, member)
    return Diag.Help.Hint("add export #{alias}.#{member} to #{place} to re-export it") if alias != "?"

    return Diag.Help.Hint(
      "#{member} is only imported in #{place}: import its module with an alias there and add export Alias.#{member}",
    )
  end

  ImportHelp.unknown_import_help(target.key, target.public, member)
end

## Loads the root file and everything it imports. A failure is a packed failure (link_failure.agc): CHECK-IMPORT-*,
## CHECK-DECL-ORDER and CHECK-REDEFINED-NAME, or the diagnostic of the lexer or the parser for a file.
def load(root: String, settings: Env.Settings) -> Result[Loaded] = load_with(root, settings, no_parses())

## Like `load`, taking from `parses` the tree of each file whose text it still has. The files are read as before, so a
## file that appeared, vanished or changed since the earlier walk is met, and the walk fails or differs as it would
## without `parses`.
def load_with(root: String, settings: Env.Settings, parses: Parses) -> Result[Loaded]
  finished = try load_root(settings, empty_walk(false, parses), root)
  ok(loaded_of(finished))
end

## Like `load`, using the check cache of the workspace (check_cache.agc): each file but the root gets its digest and
## the tree digest of this walk, and is `clean` when the cache's entry for its text vouches for that tree. With `stubs`
## a file whose text has an entry with a stub is parsed from the stub; the caller must then look at every `stubbed`
## module, which is a stand-in until it is `clean`. With the cache off it is `load`. The walk, its order, its ids and
## its failures are those of `load`, except that a stub has fewer nodes than its text.
def load_checked(root: String, settings: Env.Settings, stubs: Bool) -> Result[Loaded]
  use = settings.workspace.check_cache.on
  finished = try load_root(settings, empty_walk(false, no_parses()).with(cached: use, stubs: use and stubs), root)
  ok(loaded_of(finished))
end

## Loads several roots into one set of modules: a file that two roots reach is read, parsed and entered once, and every
## module, the roots too, gets the prefix "@N::". Each root is a transaction: the walk of a root that fails is dropped
## as a whole, so none of its modules stays, and the next root starts from the walk before it. A root whose file an
## earlier root already loaded adds nothing. `parses` is taken as `load_with` takes it.
def load_roots(roots: List[String], settings: Env.Settings, parses: Parses) -> Roots
  walk = empty_walk(true, parses)
  entries: List[Entry] = []
  for root in roots
    key = settings.workspace.real_path.call(root).unwrap_or(root)
    loaded = load_root(settings, walk, root)
    if loaded.ok?
      walk = loaded.unwrap!
      entries = entries.push(Entry(typed: root, key: key, root_dir: walk.root_dir, failure: none))
    else
      failure = Failure.unpack_failure(loaded.message)
      entries = entries.push(Entry(typed: root, key: key, root_dir: walk.root_dir, failure: some(failure)))
    end
  end

  Roots(loaded: loaded_of(walk), entries: entries)
end

private

# A file whose imports are being read: the module so far (its aliases and named imports are filled in as imports are
# read), and the index of the next import to read. pending is the key of the file that the import at next names while
# its names wait to be checked: they need the exports of that file, so they are checked once it is loaded, checked
# after the walk. "" when no import waits.
struct Frame
  module: Module
  aliases: Map[String, String]
  named: Map[String, Named]
  imports: List[Ast.ImportDecl]
  imported: List[String]
  next: Int
  pending: String
end

# seen maps a key to 1 while its file is on the stack, and to 0 once it is done.
struct Walk
  stack: List[Frame]
  seen: Map[String, Int]
  done: Map[String, Module]
  order: List[String]
  next_id: Int
  parsed: Int
  kept: Map[String, Kept]
  root_dir: String
  build: Resolve.Build
  prefixed: Bool
  cached: Bool
  stubs: Bool
  stubbed: Int
end

# A file that was read and parsed, ready to join the walk.
struct Parsed
  key: String
  file: String
  text: String
  program: Ast.Program
  first_id: Int
  name: String
  origin: Packages.Origin
  digest: String
  verified: String
  styled: Bool
  held: Map[String, String]
  stubbed: Bool
  tested: Bool
end

struct Collected
  names: Map[String, Declarations.Kind]
  public: Map[String, Declarations.Kind]
end

# A tree for a file, from the Kept files or from the parser, and whether the parser made it.
struct Taken
  program: Ast.Program
  first_id: Int
  fresh: Bool
  stubbed: Bool
end

# The modules a walk finished, as `Loaded`.
def loaded_of(walk: Walk) -> Loaded
  Loaded(order: walk.order, modules: walk.done, root_dir: walk.root_dir, parsed: walk.parsed, stubs: walk.stubbed)
end

# The walk before any file, over the trees of `parses`. `prefixed` is true when the root files get a "@N::" prefix too
# (load_roots); load keeps the names of its one root.
def empty_walk(prefixed: Bool, parses: Parses) -> Walk
  build = Resolve.Build(libs_dir: "", scope: Packages.scope_of(Project.Project.Bare))
  Walk(
    stack: [],
    seen: {},
    done: {},
    order: [],
    next_id: parses.top,
    parsed: 0,
    kept: parses.kept,
    root_dir: "",
    build: build,
    prefixed: prefixed,
    cached: false,
    stubs: false,
    stubbed: 0,
  )
end

# Loads `root` and its imports into `walk`. The root is parsed from the next free id of the files before it (or taken
# from the kept trees), and its folder and packages are its own: the project is found from the root file. A root that
# `walk` holds already adds nothing.
def load_root(settings: Env.Settings, walk: Walk, root: String) -> Result[Walk]
  workspace = settings.workspace
  known = workspace.real_path.call(root)
  if known.ok? and walk.done.has_key?(known.unwrap!)
    # The folder is this root's own, not that of the root whose walk loaded the file.
    return ok(walk.with(root_dir: Paths.directory_of(known.unwrap!)))
  end

  file = workspace.resolve_path.call(root).unwrap_or(root)
  text = try root_text(workspace, root, file)
  key = workspace.real_path.call(root)
  if !key.ok?
    # The error sits at the end of the root's tree, so a file that does not parse is reported first.
    program = try parse_source(file, text, 0)
    return error(
      Failure.fail_at(Failure.Site(file: file, span: program.span), "CHECK-IMPORT-IO", key.message, Diag.Help.NoHelp),
    )
  end

  taken = try take(walk.kept, walk.next_id, key.unwrap!, file, text, settings.test_file)
  # A kept tree (Parses) of a test file was read as one (`take`), so it already has its `main`.
  if settings.test_file and taken.fresh
    tested = try TestMain.add_main(file, taken.program)
    taken = taken.with(program: tested)
  end

  root_dir = Paths.directory_of(key.unwrap!)
  project = try Project.find(workspace, root_dir, settings.version)
  base = Packages.scope_of(project).with(
    os: settings.env.os,
    native_root: PackageCache.root(settings.env),
    agentica: settings.version,
  )

  scope = try Packages.check_manifests(workspace, base)
  if settings.test_file or settings.test_build
    scope = Packages.with_tests(scope)
  end

  scope = Packages.with_project_natives(workspace, scope, project)
  build = Resolve.Build(libs_dir: Project.library_dir(project, root_dir), scope: scope)
  first = Parsed(
    key: key.unwrap!,
    file: file,
    text: text,
    program: taken.program,
    first_id: taken.first_id,
    name: Paths.stored_name(root_dir, key.unwrap!),
    origin: Packages.project_origin(scope),
    digest: "",
    verified: "",
    styled: false,
    held: {},
    stubbed: false,
    tested: settings.test_file,
  )

  entered = try enter(settings, walk.with(root_dir: root_dir, build: build), first, taken.fresh)
  run(settings, entered)
end

# The tree of the file `key` with `text`: the kept one when its text is the same and it was read the same way
# (`tested`: as the root of a test file), and else the parse from `next_id`.
def take(kept: Map[String, Kept], next_id: Int, key: String, file: String, text: String, tested: Bool) -> Result[Taken]
  if kept.has_key?(key) and kept[key].text == text and kept[key].tested == tested
    return ok(Taken(program: kept[key].program, first_id: kept[key].first_id, fresh: false, stubbed: false))
  end

  program = try parse_source(file, text, next_id)
  ok(Taken(program: program, first_id: next_id, fresh: true, stubbed: false))
end

# The tree of an imported file for a walk that uses the check cache: the stub of its entry when the walk takes stubs
# and the stub parses, else the parse of the text. An entry is only a hint, so a stub that does not parse is not a
# failure: the text is parsed, and any failure it has is the one `load` gives.
def take_cached(walk: Walk, key: String, text: String, entry: Optional[CheckCache.Entry]) -> Result[Taken]
  case entry
    some(found) ->
      if walk.stubs and found.stub != ""
        stub = parse_source(key, found.stub, walk.next_id)
        return ok(Taken(program: stub.unwrap!, first_id: walk.next_id, fresh: true, stubbed: true)) if stub.ok?
      end

    none -> entry = entry
  end

  take(walk.kept, walk.next_id, key, key, text, false)
end

def start_span() -> Source.Span
  start = Source.Position(offset: 0, line: 1, column: 1)
  Source.Span(start: start, stop: start)
end

def parse_source(file: String, text: String, first_id: Int) -> Result[Ast.Program]
  case Lexer.lex(text)
    Diag.Outcome.Failed(problem) -> error(Failure.from_stage(file, problem))
    Diag.Outcome.Done(tokens) ->
      case Parser.parse(tokens, first_id)
        Diag.Outcome.Failed(problem) -> error(Failure.from_stage(file, problem))
        Diag.Outcome.Done(program) -> ok(program)
      end
  end
end

# Each step reads one import of the file on top of the stack, or finishes that file.
def run(settings: Env.Settings, walk: Walk) -> Result[Walk]
  return ok(walk) if walk.stack.size == 0

  following = try step(settings, walk)
  run(settings, following)
end

def step(settings: Env.Settings, walk: Walk) -> Result[Walk]
  frame = walk.stack[walk.stack.size - 1]
  return finish(walk, frame) if frame.next >= frame.imports.size

  return bind_names(settings, walk, frame, frame.imports[frame.next]) if frame.pending != ""

  read_import(settings, walk, frame, frame.imports[frame.next])
end

def finish(walk: Walk, frame: Frame) -> Result[Walk]
  blocks = Declarations.modules_of(frame.module.program.declarations)
  aliases = frame.aliases
  for block in blocks
    aliases = aliases.put(block.name, block_key(frame.module.key, block.name))
  end

  module = frame.module.with(aliases: aliases, named: frame.named, imports: frame.imported)
  # The blocks are entered first: a re-export may name one (`export Counter.start`), and a constant of the file may
  # have the type of one, so both read them from `done`.
  done = walk.with(stack: walk.stack.take(walk.stack.size - 1))
  for block in blocks
    done = try enter_block(done, module, block)
  end

  # The imports are all done: the re-exports can take their kinds and origins from the finished exports.
  module = try bind_reexports(done, module)
  if module.digest != ""
    # Every file it imports is done: the stack only finishes a file after the ones it read.
    below = module.imports.map do |imported: String| done.done[imported].tree end
    tree = CheckCache.tree_digest(shape_of(module), module.digest, below)
    module = module.with(tree: tree)
    if module.verified == tree
      module = vouched_clean(done, module)
    end
  end

  module = module.with(imports: module.imports.concat(blocks.map do |block| block_key(module.key, block.name) end))
  ok(done.with(seen: done.seen.put(module.key, 0), done: done.done.put(module.key, module)))
end

# The module that the linker makes of a module block of `file` (docs/grammar/05b-modules.md): its declarations under a
# prefix of their own, with the layout rules of a file. It sees the imports of the file, the other blocks and the
# top-level names of the file, private ones included, and its own names bare, which may not be any of those
# (`unshadowed`). It has the imports of the file, so a cache that reuses checks sees a change below the file. The file
# and the importers see only its exports, through the block's name.
def enter_block(walk: Walk, file: Module, block: Ast.ModuleDecl) -> Result[Walk]
  try Declarations.check_order(file.file, block.declarations, block.private_mark)
  collected = try collect(file.file, block.declarations)
  try unshadowed(file, block.declarations)
  key = block_key(file.key, block.name)
  named = file.named
  for name in file.names.keys
    if !Declarations.module?(file.names[name])
      named = named.put(name, Named(target: file.key, name: name))
    end
  end

  program = Ast.Program(
    id: block.id,
    declarations: block.declarations,
    module_doc: none,
    span: block.span,
    private_mark: block.private_mark,
  )

  module = Module(
    key: key,
    file: file.file,
    name: file.name,
    origin: file.origin,
    prefix: "@#{walk.seen.size + 1}::",
    first_id: file.first_id,
    text: file.text,
    program: program,
    names: collected.names,
    public: collected.public,
    aliases: file.aliases,
    named: named,
    reexports: {},
    imports: file.imports,
    digest: "",
    verified: "",
    styled: false,
    held: {},
    stubbed: false,
    tree: "",
    clean: false,
    constants: {},
    tested: false,
    block: block.name,
  )

  ok(walk.with(seen: walk.seen.put(key, 0), done: walk.done.put(key, module), order: walk.order.push(key)))
end

# Refuses a declaration of a module block whose name the file already gives a meaning: one name means one thing in a
# scope, so a block may not hide a top-level declaration, an import alias, an imported name or another block
# (CHECK-SHADOWED-NAME). `main` runs only at the top level of a file, so a block may not declare one (CHECK-MAIN).
def unshadowed(file: Module, declarations: List[Ast.Decl]) -> Result[Bool]
  for wrapped in declarations
    next if Declarations.import?(Declarations.kind_of(wrapped))

    name = Declarations.name_of(wrapped)
    site = Failure.Site(file: file.file, span: Declarations.declared_name_span(wrapped))
    if name == "main"
      return error(
        Failure.fail_at(
          site,
          "CHECK-MAIN",
          "main is not allowed in a module block",
          Failure.hint("declare main at the top level of the root file"),
        ),
      )
    end

    if file.names.has_key?(name) or file.aliases.has_key?(name) or file.named.has_key?(name)
      return error(
        Failure.fail_at(
          site,
          "CHECK-SHADOWED-NAME",
          "a module block declares a name its file already has",
          Failure.hint("rename it: the file declares or imports #{name}, and one name means one thing in a scope"),
        ),
      )
    end
  end

  ok(true)
end

# The re-exports of `module` (`export Alias.name`), in the order of the file: the alias must be an import of the file,
# the module it names must export the name, and the name must be free among the declarations, the import aliases and
# the other re-exports of the file (CHECK-IMPORT-NAME, CHECK-REDEFINED-NAME). The name joins the exports with the kind
# of the original, and reexports keeps where the original is, so an importer reads the declaration itself. A std/
# module may also re-export a builtin record or enum of a std-only family (`export LogRegistry.Event`): its users then
# write Logger.Event, and the family stays internal to std/.
def bind_reexports(walk: Walk, module: Module) -> Result[Module]
  public = module.public
  reexports = module.reexports
  for decl in Declarations.reexports_of(module.program.declarations)
    if !module.aliases.has_key?(decl.alias) and STD_ONLY.has_key?(decl.alias)
      kind = try builtin_reexport(module, decl)
      try free_reexport(module, public, decl)
      public = public.put(decl.name, kind)
      reexports = reexports.put(decl.name, Named(target: BUILTIN, name: "#{decl.alias}.#{decl.name}"))
      next
    end

    if !module.aliases.has_key?(decl.alias)
      return error(
        Failure.fail_at(
          Failure.Site(file: module.file, span: decl.alias_span),
          "CHECK-IMPORT-NAME",
          "unknown module alias",
          Failure.hint("import a module with import #{decl.alias} from \"path\""),
        ),
      )
    end

    target = walk.done[module.aliases[decl.alias]]
    at_name = Failure.Site(file: module.file, span: decl.name_span)
    if !target.public.has_key?(decl.name)
      return error(
        Failure.fail_at(
          at_name,
          "CHECK-IMPORT-NAME",
          "unknown or private imported name",
          import_name_help(walk.done, target, decl.name),
        ),
      )
    end

    try free_reexport(module, public, decl)
    origin = Named(target: target.key, name: decl.name)
    if target.reexports.has_key?(decl.name)
      origin = target.reexports[decl.name]
    end

    public = public.put(decl.name, target.public[decl.name])
    reexports = reexports.put(decl.name, origin)
  end

  ok(module.with(public: public, reexports: reexports))
end

# CHECK-REDEFINED-NAME when the re-exported name is taken among the declarations, the import aliases and the exports
# of the file so far.
def free_reexport(module: Module, public: Map[String, Declarations.Kind], decl: Ast.ReexportDecl) -> Result[Bool]
  name = decl.name
  if public.has_key?(name) or module.names.has_key?(name) or module.aliases.has_key?(name)
    return error(
      Failure.fail_at(
        Failure.Site(file: module.file, span: decl.name_span),
        "CHECK-REDEFINED-NAME",
        "duplicate or reserved re-exported name",
        Failure.hint(clash_help(module, name)),
      ),
    )
  end

  ok(true)
end

# The kind of the builtin type that `export Family.Name` re-exports, where Family is a std-only family: a record is a
# struct, an enum an enum and an opaque type (HttpWire.Client) a resource. Only std/ may name the family
# (CHECK-UNKNOWN-NAME, as for a call of it), and only a type of it (CHECK-IMPORT-NAME).
def builtin_reexport(module: Module, decl: Ast.ReexportDecl) -> Result[Declarations.Kind]
  name = "#{decl.alias}.#{decl.name}"
  if !Resolve.embedded?(module.key)
    return error(
      Failure.fail_at(
        Failure.Site(file: module.file, span: decl.alias_span),
        "CHECK-UNKNOWN-NAME",
        "unknown name \"#{decl.alias}\"",
        Failure.hint(std_only_help(decl.alias)),
      ),
    )
  elsif RECORDS.has_key?(name)
    return ok(Declarations.Kind.Struct)
  elsif ENUMS.has_key?(name)
    return ok(Declarations.Kind.Enum)
  elsif OPAQUE_TYPES.include?(name)
    return ok(Declarations.Kind.Resource)
  end

  error(
    Failure.fail_at(
      Failure.Site(file: module.file, span: decl.name_span),
      "CHECK-IMPORT-NAME",
      "#{name} is no builtin type",
      Failure.hint("a std/ module re-exports only a record, an enum or a handle type of #{decl.alias}"),
    ),
  )
end

# What to do about a re-exported name that is already taken: the alias of the file is the usual cause.
def clash_help(module: Module, name: String) -> String
  if module.aliases.has_key?(name)
    return "an import alias of this file has that name; rename the alias, as in import V from \"path\""
  end

  "another declaration or re-export of this file has that name"
end

# `module`, which its entry vouches for, as a clean module if the entry types every constant it declares and the types
# can be read in this walk; else as it is, to be checked in full.
def vouched_clean(walk: Walk, module: Module) -> Module
  names = CheckCache.constant_names(module.program)
  return module if names.size != module.held.size

  prefixes = {module.key: module.prefix}
  if names.size > 0
    for key in walk.done.keys
      prefixes = prefixes.put(key, walk.done[key].prefix)
    end
  end

  types: Map[String, T.Type] = {}
  for name in names
    return module if !module.held.has_key?(name)

    type = TypeCode.decode(module.held[name], prefixes)
    return module if !type.ok?

    types = types.put(module.prefix + name, type.unwrap!)
  end

  module.with(clean: true, constants: types)
end

# What describes a file apart from its text, for its tree digest: its key, its package, the keys its aliases name and
# the names its imports bind. Not its prefix or its stored name, which depend on where the file sits in the walk and on
# the root, and which a body check does not read, so a file checked under one root is clean under another.
def shape_of(module: Module) -> String
  origin = module.origin
  pieces = [module.key, origin.package, origin.root, origin.label, "#{module.aliases.size}"]
  for alias in module.aliases.keys.sort
    pieces = pieces.push(alias).push(module.aliases[alias])
  end

  pieces = pieces.push("#{module.named.size}")
  for local in module.named.keys.sort
    pieces = pieces.push(local).push(module.named[local].target).push(module.named[local].name)
  end

  framed = pieces.map do |text: String| CheckCache.piece(text) end
  framed.join("")
end

# One import of the file on top: the alias, the path, then the file it names (read and entered unless it was seen). The
# names of an import list wait for the file to be loaded (bind_names).
def read_import(settings: Env.Settings, walk: Walk, frame: Frame, decl: Ast.ImportDecl) -> Result[Walk]
  module = frame.module
  site = Failure.Site(file: module.file, span: decl.span)
  alias = Declarations.alias_of(decl)
  aliases = frame.aliases
  if (
    alias != "" and
    (
      aliases.has_key?(alias) or
      module.names.has_key?(alias) or
      frame.named.has_key?(alias) or
      RESERVED.include?(alias)
    )
  )
    help = Diag.Help.NoHelp
    if RESERVED.include?(alias)
      help = Failure.hint("#{alias} is a builtin type name, so it is no import alias; choose another alias")
    end

    return error(Failure.fail_at(site, "CHECK-REDEFINED-NAME", "duplicate or reserved import alias", help))
  end

  file = try Paths.module_file(decl, site)
  importer = Resolve.Importer(key: module.key, origin: module.origin)
  found = try Resolve.resolve_import(settings, walk.build, importer, file, site)
  target = found.key
  if alias != ""
    aliases = aliases.put(alias, target)
  end

  noted = frame.with(imported: frame.imported.push(target))
  with_frame = replace_top(walk, after_read(noted, aliases, target, decl))
  # The packages loaded so far are kept whether or not this file is new.
  known = with_frame.with(build: with_frame.build.with(scope: found.scope))
  state = walk.seen.get(target, -1)
  if state == 1
    return error(Failure.fail_at(site, "CHECK-IMPORT-CYCLE", "import cycle", Diag.Help.NoHelp))
  elsif state == 0
    return ok(known)
  end

  load_file(settings, known, found, site)
end

# An alias import is done once read; a name list waits for its file (pending).
def after_read(frame: Frame, aliases: Map[String, String], target: String, decl: Ast.ImportDecl) -> Frame
  return frame.with(aliases: aliases, next: frame.next + 1) if decl.names.size == 0

  frame.with(aliases: aliases, pending: target)
end

# The names of the import at next, once its file is loaded: each must be an export, keep the case rule of its kind, and
# join the names of the file like a declaration. The first problem is reported, in the order of the list.
def bind_names(settings: Env.Settings, walk: Walk, frame: Frame, decl: Ast.ImportDecl) -> Result[Walk]
  target = walk.done[frame.pending]
  named = frame.named
  aliases = frame.aliases
  for entry in decl.names
    bound = try bind_name(settings, walk.done, frame.with(aliases: aliases), target, entry, named)
    block = exported_block(target, entry.name)
    # An imported module block is an alias of the file, as `import Counter from "path"` would make.
    if block != ""
      aliases = aliases.put(entry.local, block)
    else
      named = bound
    end
  end

  ok(replace_top(walk, frame.with(named: named, aliases: aliases, next: frame.next + 1, pending: "")))
end

def bind_name(
  settings: Env.Settings,
  modules: Map[String, Module],
  frame: Frame,
  target: Module,
  entry: Ast.ImportName,
  named: Map[String, Named],
) -> Result[Map[String, Named]]
  file = frame.module.file
  if !target.public.has_key?(entry.name)
    return error(
      Failure.fail_at(
        Failure.Site(file: file, span: entry.span),
        "CHECK-IMPORT-NAME",
        "unknown or private imported name",
        import_name_help(modules, target, entry.name),
      ),
    )
  end

  kind = target.public[entry.name]
  at_local = Failure.Site(file: file, span: entry.local_span)
  if !rename_ok?(entry.local, kind)
    return error(
      Failure.fail_at(
        at_local,
        "CHECK-IMPORT-RENAME",
        "the new name does not follow the case rule of the imported name",
        Failure.hint(rename_help(kind)),
      ),
    )
  end

  taken = (
    frame.module.names.has_key?(entry.local) or
    frame.aliases.has_key?(entry.local) or
    named.has_key?(entry.local)
  )

  if taken or BARE_NAMES.include?(entry.local) or RESERVED.include?(entry.local)
    return error(
      Failure.fail_at(at_local, "CHECK-REDEFINED-NAME", "duplicate or reserved imported name", Diag.Help.NoHelp),
    )
  end

  ok(named.put(entry.local, Named(target: target.key, name: entry.name)))
end

# A struct, enum or type alias is renamed to a type name (a capital first letter), a function to a lowercase one, a
# constant to another constant name.
def rename_ok?(local: String, kind: Declarations.Kind) -> Bool
  if Declarations.constant?(kind)
    return Declarations.constant_name?(local)
  elsif Declarations.function?(kind)
    return !Declarations.type_name?(local)
  end

  Declarations.type_name?(local)
end

def rename_help(kind: Declarations.Kind) -> String
  case kind
    Declarations.Kind.Struct -> "a struct is renamed to another type name, which starts with a capital letter"
    Declarations.Kind.Enum -> "an enum is renamed to another type name, which starts with a capital letter"
    Declarations.Kind.TypeAlias -> "a type alias is renamed to another type name, which starts with a capital letter"
    Declarations.Kind.Resource -> "a resource is renamed to another type name, which starts with a capital letter"
    Declarations.Kind.Constant -> "a constant is renamed to another constant name, in capitals with underscores"
    _ -> "a function is renamed to another lowercase name"
  end
end

def replace_top(walk: Walk, frame: Frame) -> Walk = walk.with(stack: walk.stack.set(walk.stack.size - 1, frame))

def load_file(settings: Env.Settings, walk: Walk, found: Resolve.Resolution, site: Failure.Site) -> Result[Walk]
  key = found.key
  text = try imported_text(settings, key, site)
  digest = ""
  entry: Optional[CheckCache.Entry] = none
  if walk.cached
    digest = CheckCache.text_digest(text)
    entry = CheckCache.find(settings.workspace.check_cache, key, digest)
  end

  taken = try take_cached(walk, key, text, entry)
  name = found.name
  if name == ""
    name = Paths.stored_name(walk.root_dir, key)
  end

  parsed = Parsed(
    key: key,
    file: key,
    text: text,
    program: taken.program,
    first_id: taken.first_id,
    name: name,
    origin: found.origin,
    digest: digest,
    verified: vouched(entry),
    styled: styled(entry),
    held: held(entry),
    stubbed: taken.stubbed,
    tested: false,
  )

  enter(settings, walk, parsed, taken.fresh)
end

# The text of the root file: CHECK-IMPORT-IO at its start with the system's message, or LEX-INVALID-UTF8.
def root_text(workspace: Workspace.Workspace, root: String, file: String) -> Result[String]
  case workspace.read_text.call(root)
    SourceFile.Read.Text(text) -> ok(text)
    SourceFile.Read.Invalid(at) -> error(Failure.from_stage(file, SourceFile.invalid_utf8(at)))
    SourceFile.Read.Unreadable(message) ->
      site = Failure.Site(file: file, span: start_span())
      error(Failure.fail_at(site, "CHECK-IMPORT-IO", message, Diag.Help.NoHelp))
  end
end

# The text of an imported file: CHECK-IMPORT-IO at the import, or LEX-INVALID-UTF8 in the imported file.
def imported_text(settings: Env.Settings, key: String, site: Failure.Site) -> Result[String]
  case Resolve.read_source(settings, key)
    SourceFile.Read.Text(text) -> ok(text)
    SourceFile.Read.Invalid(at) -> error(Failure.from_stage(key, SourceFile.invalid_utf8(at)))
    SourceFile.Read.Unreadable(_) ->
      error(Failure.fail_at(site, "CHECK-IMPORT-IO", "cannot read import", Diag.Help.NoHelp))
  end
end

# Registers a parsed file: the declaration order, then the declared names, then it goes on the stack with the imports
# to read.
def enter(settings: Env.Settings, walk: Walk, parsed: Parsed, fresh: Bool) -> Result[Walk]
  key = parsed.key
  program = parsed.program
  try Declarations.check_order(parsed.file, program.declarations, program.private_mark)
  collected = try collect(parsed.file, program.declarations)
  count = walk.seen.size + 1
  prefix = "@#{count}::"
  if walk.order.size == 0 and !walk.prefixed
    prefix = ""
  end

  module = Module(
    key: key,
    file: parsed.file,
    name: parsed.name,
    origin: parsed.origin,
    prefix: prefix,
    first_id: parsed.first_id,
    text: parsed.text,
    program: program,
    names: collected.names,
    public: collected.public,
    aliases: {},
    named: {},
    reexports: {},
    imports: [],
    digest: parsed.digest,
    verified: parsed.verified,
    styled: parsed.styled,
    held: parsed.held,
    stubbed: parsed.stubbed,
    tree: "",
    clean: false,
    constants: {},
    tested: parsed.tested,
    block: "",
  )

  frame = Frame(
    module: module,
    aliases: {},
    named: {},
    imports: Declarations.imports_of(program.declarations),
    imported: [],
    next: 0,
    pending: "",
  )

  ok(
    walk.with(
      stack: walk.stack.push(frame),
      seen: walk.seen.put(key, 1),
      order: walk.order.push(key),
      next_id: max_of(walk.next_id, Ast.next_free_id(program)),
      parsed: counted(walk.parsed, fresh),
      stubbed: counted(walk.stubbed, parsed.stubbed),
    ),
  )
end

# The types of the constants that an entry holds, empty when there is no entry.
def held(entry: Optional[CheckCache.Entry]) -> Map[String, String]
  case entry
    some(found) -> found.constants
    none -> {}
  end
end

# The tree digest that an entry vouches for, "" when there is no entry.
def vouched(entry: Optional[CheckCache.Entry]) -> String
  case entry
    some(found) -> found.tree
    none -> ""
  end
end

# Whether an entry says that the text follows the style rule blank_line_after_end, false when there is no entry.
def styled(entry: Optional[CheckCache.Entry]) -> Bool
  case entry
    some(found) -> found.styled
    none -> false
  end
end

# A file that came from the Kept files lies below the next id, so only a parsed one moves it.
def max_of(a: Int, b: Int) -> Int
  return a if a > b

  b
end

def counted(parsed: Int, fresh: Bool) -> Int
  return parsed + 1 if fresh

  parsed
end

# The names a file declares, and those it exports; a repeated name, a builtin name, a reserved type name or an enum
# named like a std-only family with records (Builtins.record_family?) is CHECK-REDEFINED-NAME at the declaration (the
# span of Declarations.name_span_of).
def collect(file: String, declarations: List[Ast.Decl]) -> Result[Collected]
  names: Map[String, Declarations.Kind] = {}
  public: Map[String, Declarations.Kind] = {}
  for wrapped in declarations
    kind = Declarations.kind_of(wrapped)
    next if Declarations.import?(kind)

    name = Declarations.name_of(wrapped)
    family_enum = Declarations.enum?(kind) and Builtins.record_family?(name)
    if names.has_key?(name) or BARE_NAMES.include?(name) or RESERVED.include?(name) or family_enum
      help = Diag.Help.NoHelp
      if family_enum
        help = Failure.hint(
          "#{name} is a builtin family with records of its own, so an enum may not have the name: its variants " +
          "would clash with them; a struct or a type alias may",
        )
      end

      return error(
        Failure.fail_at(
          Failure.Site(file: file, span: Declarations.name_span_of(wrapped)),
          "CHECK-REDEFINED-NAME",
          "duplicate or reserved declaration",
          help,
        ),
      )
    end

    names = names.put(name, kind)
    if Declarations.exported?(wrapped)
      public = public.put(name, kind)
    end
  end

  ok(Collected(names: names, public: public))
end

# The public module block of `file` that has `member` among its public names, or "".
def block_holding(modules: Map[String, Module], file: Module, member: String) -> String
  for block in Declarations.modules_of(file.program.declarations)
    key = block_key(file.key, block.name)
    held = modules.has_key?(key) and modules[key].public.has_key?(member)
    return block.name if held and file.public.has_key?(block.name)
  end

  ""
end

# The alias under which `file` imports a module that exports `member`, "?" when it imports `member` by name from a
# module it has no alias for, or "" when it does not import `member`.
def imported_alias(modules: Map[String, Module], file: Module, member: String) -> String
  for alias in file.aliases.keys.sort
    key = file.aliases[alias]
    next if key == block_key(file.key, alias)

    return alias if modules.has_key?(key) and modules[key].public.has_key?(member)
  end

  return "" if not file.named.has_key?(member)

  origin = file.named[member].target
  for alias in file.aliases.keys.sort
    return alias if file.aliases[alias] == origin
  end

  "?"
end
