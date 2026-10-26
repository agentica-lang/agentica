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

import {BARE_NAMES, RESERVED} from "../catalog/builtins"
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
import TypeCode from "type_code"
import Workspace from "workspace"

## A name bound by import {Name} from "path" (or {Name as Local}): the key of the module that exports it and the
## exported name.
export struct Named
  target: String
  name: String
end

## A file of the program once it is loaded. named maps each local name of an import list to what it names. name is the
## path the file is stored under (Paths.stored_name, or `pkg/name@version/path` for a file of a package), and origin
## the package it belongs to. imports lists the keys of the files it imports, in the order of its import lines. The
## last seven fields are for the cache of checked modules (check_cache.agc) and are empty or false for a walk that does
## not use it, and for the root file: digest is the SHA-256 of the text, verified the tree digest that the cache's
## entry for this text vouches for and held the types of its constants (as type_code.agc writes them), stubbed whether
## program is the parse of the stub of that entry rather than of the text, tree the tree digest of this walk, and clean
## whether the two are the same and the entry types every constant, so the bodies and constants need no check:
## constants then has the type of each constant by its linked name.
export struct Module
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
  imports: List[String]
  digest: String
  verified: String
  held: Map[String, String]
  stubbed: Bool
  tree: String
  clean: Bool
  constants: Map[String, T.Type]
end

## Every module of a program. order lists the keys with the root first, each file before the files its imports read; a
## file imported twice appears once. root_dir is the folder of the root file. parsed is the number of files that this
## walk lexed and parsed (stubs included); the others came from the Kept files it was given. stubs counts the files
## parsed from a stub.
export struct Loaded
  order: List[String]
  modules: Map[String, Module]
  root_dir: String
  parsed: Int
  stubs: Int
end

## A file parsed by an earlier walk: its text, the first id of its tree and the tree. It can stand for the file in a
## later walk while the file has this text.
export struct Kept
  text: String
  first_id: Int
  program: Ast.Program
end

## The files that a walk may take instead of parsing, by key, and top, an id above every id of those files (the ranges
## of the files in `kept` must not overlap). A file that has to be parsed gets ids from top on.
export struct Parses
  kept: Map[String, Kept]
  top: Int
end

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
  held: Map[String, String]
  stubbed: Bool
end

struct Collected
  names: Map[String, Declarations.Kind]
  public: Map[String, Declarations.Kind]
end

## One root of load_roots: the path as it was given, the key of its file, the folder of the root and, when it did not
## load, why (a packed failure read back, link_failure.agc).
export struct Entry
  typed: String
  key: String
  root_dir: String
  failure: Ast.Optional[Failure.Failure]
end

## What load_roots gave: every module of the roots that loaded, and one Entry for each root, in the order given. The
## modules of a root that failed are not in `loaded`.
export struct Roots
  loaded: Loaded
  entries: List[Entry]
end

# A tree for a file, from the Kept files or from the parser, and whether the parser made it.
struct Taken
  program: Ast.Program
  first_id: Int
  fresh: Bool
  stubbed: Bool
end

## Parses nothing again: the files are numbered one after the other from 0.
export def no_parses() -> Parses
  return Parses(kept: {}, top: 0)
end

## Loads the root file and everything it imports. A failure is a packed failure (link_failure.agc): CHECK-IMPORT-*,
## CHECK-DECL-ORDER and CHECK-REDEFINED-NAME, or the diagnostic of the lexer or the parser for a file.
export def load(root: String, settings: Env.Settings) -> Result[Loaded]
  return load_with(root, settings, no_parses())
end

## Like `load`, taking from `parses` the tree of each file whose text it still has. The files are read as before, so a
## file that appeared, vanished or changed since the earlier walk is met, and the walk fails or differs as it would
## without `parses`.
export def load_with(root: String, settings: Env.Settings, parses: Parses) -> Result[Loaded]
  finished = try load_root(settings, empty_walk(false, parses), root)
  return ok(loaded_of(finished))
end

## Like `load`, using the check cache of the workspace (check_cache.agc): each file but the root gets its digest and
## the tree digest of this walk, and is `clean` when the cache's entry for its text vouches for that tree. With `stubs`
## a file whose text has an entry with a stub is parsed from the stub; the caller must then look at every `stubbed`
## module, which is a stand-in until it is `clean`. With the cache off it is `load`. The walk, its order, its ids and
## its failures are those of `load`, except that a stub has fewer nodes than its text.
export def load_checked(root: String, settings: Env.Settings, stubs: Bool) -> Result[Loaded]
  use = settings.workspace.check_cache.on
  finished = try load_root(settings, empty_walk(false, no_parses()).with(cached: use, stubs: use and stubs), root)
  return ok(loaded_of(finished))
end

## Loads several roots into one set of modules: a file that two roots reach is read, parsed and entered once, and every
## module, the roots too, gets the prefix "@N::". Each root is a transaction: the walk of a root that fails is dropped
## as a whole, so none of its modules stays, and the next root starts from the walk before it. A root whose file an
## earlier root already loaded adds nothing. `parses` is taken as `load_with` takes it.
export def load_roots(roots: List[String], settings: Env.Settings, parses: Parses) -> Roots
  walk = empty_walk(true, parses)
  entries: List[Entry] = []
  for root in roots
    key = settings.workspace.real_path.call(root).unwrap_or(root)
    loaded = load_root(settings, walk, root)
    if loaded.ok?
      walk = loaded.unwrap!
      entries = entries.push(
        Entry(typed: root, key: key, root_dir: walk.root_dir, failure: Ast.Optional.Absent),
      )
    else
      failure = Failure.unpack_failure(loaded.message)
      entries = entries.push(
        Entry(typed: root, key: key, root_dir: walk.root_dir, failure: Ast.Optional.Present(failure)),
      )
    end
  end

  return Roots(loaded: loaded_of(walk), entries: entries)
end

# The modules a walk finished, as `Loaded`.
def loaded_of(walk: Walk) -> Loaded
  return Loaded(
    order: walk.order,
    modules: walk.done,
    root_dir: walk.root_dir,
    parsed: walk.parsed,
    stubs: walk.stubbed,
  )
end

# The walk before any file, over the trees of `parses`. `prefixed` is true when the root files get a "@N::" prefix too
# (load_roots); load keeps the names of its one root.
def empty_walk(prefixed: Bool, parses: Parses) -> Walk
  build = Resolve.Build(libs_dir: "", scope: Packages.scope_of(Project.Project.Bare))
  return Walk(
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

  taken = try take(walk.kept, walk.next_id, key.unwrap!, file, text)
  root_dir = Paths.directory_of(key.unwrap!)
  project = try Project.find(workspace, root_dir)
  base = Packages.scope_of(project).with(os: settings.env.os, native_root: PackageCache.root(settings.env))
  scope = try Packages.check_manifests(workspace, base)
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
    held: {},
    stubbed: false,
  )
  entered = try enter(settings, walk.with(root_dir: root_dir, build: build), first, taken.fresh)
  return run(settings, entered)
end

# The tree of the file `key` with `text`: the kept one when its text is the same, and else the parse from `next_id`.
def take(kept: Map[String, Kept], next_id: Int, key: String, file: String, text: String) -> Result[Taken]
  if kept.has_key?(key) and kept[key].text == text
    return ok(Taken(program: kept[key].program, first_id: kept[key].first_id, fresh: false, stubbed: false))
  end

  program = try parse_source(file, text, next_id)
  return ok(Taken(program: program, first_id: next_id, fresh: true, stubbed: false))
end

# The tree of an imported file for a walk that uses the check cache: the stub of its entry when the walk takes stubs
# and the stub parses, else the parse of the text. An entry is only a hint, so a stub that does not parse is not a
# failure: the text is parsed, and any failure it has is the one `load` gives.
def take_cached(walk: Walk, key: String, text: String, entry: Ast.Optional[CheckCache.Entry]) -> Result[Taken]
  case entry
    Ast.Optional.Present(found) ->
      if walk.stubs and found.stub != ""
        stub = parse_source(key, found.stub, walk.next_id)
        if stub.ok?
          return ok(Taken(program: stub.unwrap!, first_id: walk.next_id, fresh: true, stubbed: true))
        end
      end

    Ast.Optional.Absent -> entry = entry
  end

  return take(walk.kept, walk.next_id, key, key, text)
end

def start_span() -> Source.Span
  start = Source.Position(offset: 0, line: 1, column: 1)
  return Source.Span(start: start, stop: start)
end

def parse_source(file: String, text: String, first_id: Int) -> Result[Ast.Program]
  case Lexer.lex(text)
    Diag.Outcome.Failed(problem) -> return error(Failure.from_stage(file, problem))
    Diag.Outcome.Done(tokens) ->
      case Parser.parse(tokens, first_id)
        Diag.Outcome.Failed(problem) -> return error(Failure.from_stage(file, problem))
        Diag.Outcome.Done(program) -> return ok(program)
      end
  end
end

# Each step reads one import of the file on top of the stack, or finishes that file.
def run(settings: Env.Settings, walk: Walk) -> Result[Walk]
  if walk.stack.size == 0
    return ok(walk)
  end

  following = try step(settings, walk)
  return run(settings, following)
end

def step(settings: Env.Settings, walk: Walk) -> Result[Walk]
  frame = walk.stack[walk.stack.size - 1]
  if frame.next >= frame.imports.size
    return ok(finish(walk, frame))
  end

  if frame.pending != ""
    return bind_names(settings, walk, frame, frame.imports[frame.next])
  end

  return read_import(settings, walk, frame, frame.imports[frame.next])
end

def finish(walk: Walk, frame: Frame) -> Walk
  module = frame.module.with(
    aliases: frame.aliases,
    named: frame.named,
    imports: frame.imported,
  )
  if module.digest != ""
    # Every file it imports is done: the stack only finishes a file after the ones it read.
    below = module.imports.map do |imported: String| walk.done[imported].tree end
    tree = CheckCache.tree_digest(shape_of(module), module.digest, below)
    module = module.with(tree: tree)
    if module.verified == tree
      module = vouched_clean(walk, module)
    end
  end

  return walk.with(
    stack: walk.stack.take(walk.stack.size - 1),
    seen: walk.seen.put(module.key, 0),
    done: walk.done.put(module.key, module),
  )
end

# `module`, which its entry vouches for, as a clean module if the entry types every constant it declares and the types
# can be read in this walk; else as it is, to be checked in full.
def vouched_clean(walk: Walk, module: Module) -> Module
  names = CheckCache.constant_names(module.program)
  if names.size != module.held.size
    return module
  end

  prefixes = {module.key: module.prefix}
  if names.size > 0
    for key in walk.done.keys
      prefixes = prefixes.put(key, walk.done[key].prefix)
    end
  end

  types: Map[String, T.Type] = {}
  for name in names
    if !module.held.has_key?(name)
      return module
    end

    type = TypeCode.decode(module.held[name], prefixes)
    if !type.ok?
      return module
    end

    types = types.put(module.prefix + name, type.unwrap!)
  end

  return module.with(clean: true, constants: types)
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

  return pieces.map do |text: String| CheckCache.piece(text) end.join("")
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
    return error(Failure.fail_at(site, "CHECK-REDEFINED-NAME", "duplicate or reserved import alias", Diag.Help.NoHelp))
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

  return load_file(settings, known, found, site)
end

# An alias import is done once read; a name list waits for its file (pending).
def after_read(frame: Frame, aliases: Map[String, String], target: String, decl: Ast.ImportDecl) -> Frame
  if decl.names.size == 0
    return frame.with(aliases: aliases, next: frame.next + 1)
  end

  return frame.with(aliases: aliases, pending: target)
end

# The names of the import at next, once its file is loaded: each must be an export, keep the case rule of its kind, and
# join the names of the file like a declaration. The first problem is reported, in the order of the list.
def bind_names(settings: Env.Settings, walk: Walk, frame: Frame, decl: Ast.ImportDecl) -> Result[Walk]
  target = walk.done[frame.pending]
  named = frame.named
  for entry in decl.names
    named = try bind_name(settings, frame, target, entry, named)
  end

  return ok(replace_top(walk, frame.with(named: named, next: frame.next + 1, pending: "")))
end

def bind_name(
  settings: Env.Settings,
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
        ImportHelp.unknown_import_help(target.key, target.public, entry.name),
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

  return ok(named.put(entry.local, Named(target: target.key, name: entry.name)))
end

# A struct, enum or type alias is renamed to a type name (a capital first letter), a function to a lowercase one, a
# constant to another constant name.
def rename_ok?(local: String, kind: Declarations.Kind) -> Bool
  if Declarations.constant?(kind)
    return Declarations.constant_name?(local)
  elsif Declarations.function?(kind)
    return !Declarations.type_name?(local)
  end

  return Declarations.type_name?(local)
end

def rename_help(kind: Declarations.Kind) -> String
  case kind
    Declarations.Kind.Struct -> return "a struct is renamed to another type name, which starts with a capital letter"
    Declarations.Kind.Enum -> return "an enum is renamed to another type name, which starts with a capital letter"
    Declarations.Kind.TypeAlias ->
      return "a type alias is renamed to another type name, which starts with a capital letter"
    Declarations.Kind.Resource ->
      return "a resource is renamed to another type name, which starts with a capital letter"
    Declarations.Kind.Constant -> return "a constant is renamed to another constant name, in capitals with underscores"
    _ -> return "a function is renamed to another lowercase name"
  end
end

def replace_top(walk: Walk, frame: Frame) -> Walk
  return walk.with(stack: walk.stack.set(walk.stack.size - 1, frame))
end

def load_file(settings: Env.Settings, walk: Walk, found: Resolve.Resolution, site: Failure.Site) -> Result[Walk]
  key = found.key
  text = try imported_text(settings, key, site)
  digest = ""
  entry: Ast.Optional[CheckCache.Entry] = Ast.Optional.Absent
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
    held: held(entry),
    stubbed: taken.stubbed,
  )
  return enter(settings, walk, parsed, taken.fresh)
end

# The text of the root file: CHECK-IMPORT-IO at its start with the system's message, or LEX-INVALID-UTF8.
def root_text(workspace: Workspace.Workspace, root: String, file: String) -> Result[String]
  case workspace.read_text.call(root)
    SourceFile.Read.Text(text) -> return ok(text)
    SourceFile.Read.Invalid(at) -> return error(Failure.from_stage(file, SourceFile.invalid_utf8(at)))
    SourceFile.Read.Unreadable(message) ->
      site = Failure.Site(file: file, span: start_span())
      return error(Failure.fail_at(site, "CHECK-IMPORT-IO", message, Diag.Help.NoHelp))
  end
end

# The text of an imported file: CHECK-IMPORT-IO at the import, or LEX-INVALID-UTF8 in the imported file.
def imported_text(settings: Env.Settings, key: String, site: Failure.Site) -> Result[String]
  case Resolve.read_source(settings, key)
    SourceFile.Read.Text(text) -> return ok(text)
    SourceFile.Read.Invalid(at) -> return error(Failure.from_stage(key, SourceFile.invalid_utf8(at)))
    SourceFile.Read.Unreadable(_) ->
      return error(Failure.fail_at(site, "CHECK-IMPORT-IO", "cannot read import", Diag.Help.NoHelp))
  end
end

# Registers a parsed file: the declaration order, then the declared names, then it goes on the stack with the imports
# to read.
def enter(settings: Env.Settings, walk: Walk, parsed: Parsed, fresh: Bool) -> Result[Walk]
  key = parsed.key
  program = parsed.program
  try Declarations.check_order(parsed.file, program.declarations)
  collected = try collect(settings, parsed.file, program.declarations)
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
    imports: [],
    digest: parsed.digest,
    verified: parsed.verified,
    held: parsed.held,
    stubbed: parsed.stubbed,
    tree: "",
    clean: false,
    constants: {},
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
  return ok(
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
def held(entry: Ast.Optional[CheckCache.Entry]) -> Map[String, String]
  case entry
    Ast.Optional.Present(found) -> return found.constants
    Ast.Optional.Absent -> return {}
  end
end

# The tree digest that an entry vouches for, "" when there is no entry.
def vouched(entry: Ast.Optional[CheckCache.Entry]) -> String
  case entry
    Ast.Optional.Present(found) -> return found.tree
    Ast.Optional.Absent -> return ""
  end
end

# A file that came from the Kept files lies below the next id, so only a parsed one moves it.
def max_of(a: Int, b: Int) -> Int
  if a > b
    return a
  end

  return b
end

def counted(parsed: Int, fresh: Bool) -> Int
  if fresh
    return parsed + 1
  end

  return parsed
end

# The names a file declares, and those it exports; a repeated name, a builtin name or a reserved type name is
# CHECK-REDEFINED-NAME at the declaration name.
def collect(settings: Env.Settings, file: String, declarations: List[Ast.Decl]) -> Result[Collected]
  names: Map[String, Declarations.Kind] = {}
  public: Map[String, Declarations.Kind] = {}
  for wrapped in declarations
    kind = Declarations.kind_of(wrapped)
    if Declarations.import?(kind)
      next
    end

    name = Declarations.name_of(wrapped)
    if names.has_key?(name) or BARE_NAMES.include?(name) or RESERVED.include?(name)
      return error(
        Failure.fail_at(
          Failure.Site(file: file, span: Declarations.name_span_of(wrapped)),
          "CHECK-REDEFINED-NAME",
          "duplicate or reserved declaration",
          Diag.Help.NoHelp,
        ),
      )
    end

    names = names.put(name, kind)
    if Declarations.exported?(wrapped)
      public = public.put(name, kind)
    end
  end

  return ok(Collected(names: names, public: public))
end
