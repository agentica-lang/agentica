## The module loader: starting at the root file, reads, lexes and parses every file the imports reach, once, and checks each one. This is the first half of link-program in src/modules.rkt (the visit function); rewrite.agc is the second.
##
## The walk is a loop over an explicit stack of files that still have imports to read, so a long chain of imports uses no VM call depth. Files are met in the order Racket meets them (a file is read at its import, before the imports after it), so the first failure is the same, and so are the node ids: every file is parsed from the next free id of the file read before it (parse, Ast.next_free_id).

import "ast" as Ast
import "declarations" as Declarations
import "diagnostic" as Diag
import "import_path" as Paths
import "lexer" as Lexer
import "link_env" as Env
import "link_failure" as Failure
import "parser" as Parser
import "resolve_import" as Resolve
import "source" as Source

## A file of the program once it is loaded.
export struct Module
  key: String
  file: String
  prefix: String
  first_id: Int
  program: Ast.Program
  names: Map[String, String]
  public: Map[String, String]
  aliases: Map[String, String]
end

## Every module of a program. order lists the keys with the root first, each file before the files its imports read; a file imported twice appears once. root_dir is the folder of the root file.
export struct Loaded
  order: List[String]
  modules: Map[String, Module]
  root_dir: String
end

# A file whose imports are being read: the module so far (its aliases are filled in as imports are read), and the index of the next import to read.
struct Frame
  module: Module
  aliases: Map[String, String]
  imports: List[Ast.ImportDecl]
  next: Int
end

# seen maps a key to 1 while its file is on the stack, and to 0 once it is done.
struct Walk
  stack: List[Frame]
  seen: Map[String, Int]
  done: Map[String, Module]
  order: List[String]
  next_id: Int
  root_dir: String
end

struct Collected
  names: Map[String, String]
  public: Map[String, String]
end

## Loads the root file and everything it imports. A failure is a packed failure (link_failure.agc): CHECK-IMPORT-*, CHECK-DECL-ORDER and CHECK-REDEFINED-NAME, or the diagnostic of the lexer or the parser for a file.
export def load(root: String, settings: Env.Settings) -> Result[Loaded]
  file = Path.resolve(root).unwrap_or(root)
  text = File.read_text(root, timeout())
  if !text.ok?
    return error(Failure.fail_at(Failure.Site(file: file, span: start_span()), "CHECK-IMPORT-IO", text.message, Diag.Help.NoHelp))
  end
  program = try parse_source(file, text.unwrap!, 0)
  key = Path.real(root)
  if !key.ok?
    return error(Failure.fail_at(Failure.Site(file: file, span: program.span), "CHECK-IMPORT-IO", key.message, Diag.Help.NoHelp))
  end
  empty = Walk(stack: [], seen: {}, done: {}, order: [], next_id: 0, root_dir: Paths.directory_of(key.unwrap!))
  walk = try enter(settings, empty, key.unwrap!, file, program, 0)
  finished = try run(settings, walk)
  return ok(Loaded(order: finished.order, modules: finished.done, root_dir: finished.root_dir))
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
  return read_import(settings, walk, frame, frame.imports[frame.next])
end

def finish(walk: Walk, frame: Frame) -> Walk
  m = frame.module
  module = Module(key: m.key, file: m.file, prefix: m.prefix, first_id: m.first_id, program: m.program, names: m.names, public: m.public, aliases: frame.aliases)
  return Walk(stack: walk.stack.take(walk.stack.size - 1), seen: walk.seen.put(m.key, 0), done: walk.done.put(m.key, module), order: walk.order, next_id: walk.next_id, root_dir: walk.root_dir)
end

# One import of the file on top: the alias, the path, then the file it names (read and entered unless it was seen).
def read_import(settings: Env.Settings, walk: Walk, frame: Frame, decl: Ast.ImportDecl) -> Result[Walk]
  module = frame.module
  site = Failure.Site(file: module.file, span: decl.span)
  if frame.aliases.has_key?(decl.alias) or module.names.has_key?(decl.alias) or settings.reserved.include?(decl.alias)
    return error(Failure.fail_at(site, "CHECK-REDEFINED-NAME", "duplicate or reserved import alias", Diag.Help.NoHelp))
  end
  file = try Paths.module_file(decl.path, decl.alias, site)
  target = try Resolve.resolve_import(settings, walk.root_dir, module.key, file, site)
  moved = Frame(module: module, aliases: frame.aliases.put(decl.alias, target), imports: frame.imports, next: frame.next + 1)
  with_frame = replace_top(walk, moved)
  state = walk.seen.get(target, -1)
  if state == 1
    return error(Failure.fail_at(site, "CHECK-IMPORT-CYCLE", "import cycle", Diag.Help.NoHelp))
  elsif state == 0
    return ok(with_frame)
  end
  return load_file(settings, with_frame, target, site)
end

def replace_top(walk: Walk, frame: Frame) -> Walk
  return Walk(stack: walk.stack.set(walk.stack.size - 1, frame), seen: walk.seen, done: walk.done, order: walk.order, next_id: walk.next_id, root_dir: walk.root_dir)
end

def load_file(settings: Env.Settings, walk: Walk, key: String, site: Failure.Site) -> Result[Walk]
  text = File.read_text(Resolve.source_path(settings, key), timeout())
  if !text.ok?
    return error(Failure.fail_at(site, "CHECK-IMPORT-IO", "cannot read import", Diag.Help.NoHelp))
  end
  program = try parse_source(key, text.unwrap!, walk.next_id)
  return enter(settings, walk, key, key, program, walk.next_id)
end

# Registers a parsed file: the declaration order, then the declared names, then it goes on the stack with the imports to read.
def enter(settings: Env.Settings, walk: Walk, key: String, file: String, program: Ast.Program, first_id: Int) -> Result[Walk]
  try Declarations.check_order(file, program.declarations)
  collected = try collect(settings, file, program.declarations)
  count = walk.seen.size + 1
  prefix = "@" + count.to_s + "::"
  if walk.order.size == 0
    prefix = ""
  end
  module = Module(key: key, file: file, prefix: prefix, first_id: first_id, program: program, names: collected.names, public: collected.public, aliases: {})
  frame = Frame(module: module, aliases: {}, imports: Declarations.imports_of(program.declarations), next: 0)
  return ok(Walk(stack: walk.stack.push(frame), seen: walk.seen.put(key, 1), done: walk.done, order: walk.order.push(key), next_id: Ast.next_free_id(program), root_dir: walk.root_dir))
end

# The names a file declares, and those it exports; a repeated name, a builtin name or a reserved type name is CHECK-REDEFINED-NAME at the declaration.
def collect(settings: Env.Settings, file: String, declarations: List[Ast.Decl]) -> Result[Collected]
  names: Map[String, String] = {}
  public: Map[String, String] = {}
  for wrapped in declarations
    kind = Declarations.kind_of(wrapped)
    if kind == "import"
      next
    end
    name = Declarations.name_of(wrapped)
    if names.has_key?(name) or settings.bare_builtins.include?(name) or settings.reserved.include?(name)
      return error(Failure.fail_at(Failure.Site(file: file, span: Declarations.span_of(wrapped)), "CHECK-REDEFINED-NAME", "duplicate or reserved declaration", Diag.Help.NoHelp))
    end
    names = names.put(name, kind)
    if Declarations.exported?(wrapped)
      public = public.put(name, kind)
    end
  end
  return ok(Collected(names: names, public: public))
end

# Every file system call here has this deadline, in milliseconds.
def timeout() -> Int
  return 10000
end
