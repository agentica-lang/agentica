## The session of `agentica repl` on the front end's side: the declarations and the names that the entries so far made,
## and how each new entry becomes the program the child loads (repl_image.agc) and the request that runs it.
##
## Each entry is compiled from one virtual file, `file`, through the stages as they are: the current declarations of
## the session, those of the entry, and a function that runs the entry's statements and takes every name of the
## session as a parameter. The checker gives the type of each name (a first check), then the function gives the value
## to show and every name back in a struct (a second check), and that program is lowered and merged over the image.
## The lines of the file map to the lines of the session, which count every line typed, so a message points at what
## the user typed (`(repl):12:5`).

import Front from "../analysis/front"
import Writer from "../bytecode/bytecode_writer"
import Diag from "../diagnostics/diagnostic"
import Problems from "../diagnostics/problem"
import Lowering from "../lower/lowering"
import Declarations from "../modules/declarations"
import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Linker from "../modules/linker"
import Overlay from "../modules/overlay"
import TypeAt from "../query/type_at"
import Ast from "../syntax/ast"
import Lexer from "../syntax/lexer"
import Parser from "../syntax/parser"
import Source from "../syntax/source"
import SourceFile from "../syntax/source_file"
import Tokens from "../syntax/token"
import T from "../syntax/types"
import Image from "repl_image"

## A name of the session: its type as the session's file writes it, the slot of the child that holds its value, the
## structs and enums its type names, and their entries in the image when it was bound (Image.entries).
struct Binding
  name: String
  type: String
  slot: Int
  types: List[String] = []
  entries: Map[String, Int] = {}
end

## A declaration of the session: the name it declares ("" for an import), its text, its first line and its rank in a
## file: imports, constants, types, then functions. key is what an import imports: the same file under the same names
## is one import, however its path is written.
struct Piece
  name: String
  text: String
  line: Int
  rank: Int = 3
  key: String = ""
end

## The lines of the session that `:load` entered from the file `file` (as typed), from line `first` on.
struct Load
  file: String
  first: Int
  count: Int
end

## The session. `file` is the path of its virtual file, `text` every line typed so far, `lines` their number, `slots`
## the number of slots of the child in use, `image` what the child holds, `loads` the lines that files entered, and
## `folder` the folder that the relative imports of the entry being compiled resolve from ("" for the session's).
struct Session
  file: String
  pieces: List[Piece]
  bindings: List[Binding]
  text: String
  lines: Int
  entries: Int
  slots: Int
  image: Image.Image
  loads: List[Load] = []
  folder: String = ""
end

## The first program of a session, which serves the entries, and the session that has only it.
enum Started
  Ready(Session, Bytes)
  Failed(Problems.Problem)
end

## What the child is sent for an entry: the program (empty when the child has it already), the number of the entry
## function, the slots it reads and writes, the type of the value it shows ("" for none), the names it binds anew or
## with a new type, the names it declares, the names whose struct or enum it declared again, which the session drops,
## and the names it binds that the session cannot keep, as their type is private to an imported file. `ran` is the
## session after the entry, and `loaded` the one after a failure of it, when the child has the program but not the
## declarations and names of the entry.
struct Request
  bytes: Bytes
  entry: Int
  reads: List[Int]
  writes: List[Int]
  shown: String
  bound: List[Binding]
  declared: List[String]
  dropped: List[String]
  skipped: List[String]
  ran: Session
  loaded: Session
end

## An entry compiled: the request, an entry that needs more lines, or the first problem.
enum Compiled
  Run(Request)
  Incomplete
  Failed(Problems.Problem)
end

## The type of an expression (`:type`), an expression that needs more lines, or the first problem.
enum Typed
  Type(String)
  Incomplete
  Failed(Problems.Problem)
end

## Whether a problem's file is the session's virtual file, which a problem names by its whole path.
def session_file?(session: Session, file: String) -> Bool = file == session.file or file.end_with?("/#{session.file}")

## Starts a session in the virtual file `file`, whose folder is the base of its imports. The first program is in a
## file of its own, so the lines of its spans never meet those of the session's text.
def start(file: String, settings: Env.Settings) -> Started
  base = "#{file} serve"
  checked = Front.query_file(base, over(settings, base, SERVE))
  case checked
    Front.Outcome.Rejected(problem) -> Started.Failed(problem)
    Front.Outcome.Done(front) ->
      case Lowering.lower(front.linked, front.checked)
        Lowering.Lowered.Failed(problem) -> Started.Failed(problem)
        Lowering.Lowered.Done(program) ->
          over = Writer.write_over(program, settings.version, Writer.no_tables())
          case over.written
            Writer.Written.Failed(problem) -> Started.Failed(problem)
            Writer.Written.Done(bytes) ->
              image = Image.first(program, over.tables)
              Started.Ready(
                Session(file: file, pieces: [], bindings: [], text: "", lines: 0, entries: 0, slots: 0, image: image),
                bytes,
              )
          end
      end
  end
end

## The session with the lines of an entry that did not run, so the lines of the next one count after them.
def typed(session: Session, text: String) -> Session
  session.with(text: session.text + text + "\n", lines: session.lines + text.split("\n").size, folder: "")
end

## Compiles the text of the file `file` as one entry: its `private` line is left out, its relative imports resolve
## from `folder` (the file's folder, from the working folder), and a problem in its lines names the file.
def load(session: Session, file: String, folder: String, text: String, settings: Env.Settings) -> Compiled
  lines = public_text(text).split("\n")
  load = Load(file: file, first: session.lines + 1, count: lines.size)
  compile(session.with(loads: session.loads.push(load), folder: folder), lines.join("\n"), settings)
end

## Compiles an entry, whose first line is the one after the session's.
def compile(session: Session, text: String, settings: Env.Settings) -> Compiled
  case items_of(session, text)
    Items.Incomplete -> Compiled.Incomplete
    Items.Failed(problem) -> Compiled.Failed(problem)
    Items.Found(items) -> compile_items(session, text, items, settings)
  end
end

## The type of the expression `text` in the session, which runs nothing.
def type_of(session: Session, text: String, settings: Env.Settings) -> Typed
  case items_of(session, text)
    Items.Incomplete -> Typed.Incomplete
    Items.Failed(problem) -> Typed.Failed(problem)
    Items.Found(items) ->
      plan = planned(session, text, items, [], session.entries + 1)
      case first_check(session, plan, settings)
        Checks.Failed(problem) -> Typed.Failed(problem)
        Checks.Done(found) ->
          return Typed.Failed(not_expression(session, text)) if !plan.shows

          Typed.Type(found.shown)
      end
  end
end

private

# The base of every session: main serves the entries.
SERVE = "def main() -> Void\n  FrontEnd.serve_session()\nend\n"
# The problems of the lexer that the next lines may close: a delimiter or a heredoc still open at the end.
OPEN_CODES = ["LEX-UNCLOSED-DELIMITER", "LEX-UNTERMINATED-HEREDOC"]
# The field of the value the entry shows, and the start of the names of the function and the struct of an entry.
SHOWN = "repl_shown_"
ENTRY = "repl_entry_"
RECORD = "ReplEntry"
RESERVED = [SHOWN, ENTRY, RECORD]
BLANKS = Set.new([" ", "\t", "\n", "\r"])

# The items of an entry, or an entry that needs more lines.
enum Items
  Found(List[Parser.EntryItem])
  Incomplete
  Failed(Problems.Problem)
end

# The plan of an entry's file: the declarations kept and added, the statements, the parameters, which names a struct,
# enum or alias of the entry drops, and whether its last item is an expression whose value it shows.
struct Plan
  number: Int
  pieces: List[Piece]
  statements: List[Piece]
  params: List[Binding]
  declared: List[String]
  dropped: List[String]
  shows: Bool
end

# What the first check found: the type of the shown value ("" for none or Void) and the names the entry binds.
struct Found
  shown: String
  bindings: List[Binding]
  skipped: List[String] = []
end

enum Checks
  Done(Found)
  Failed(Problems.Problem)
end

# One compile of an entry: what it gives, the names of the session that hold values of a type declared again, or the
# first problem.
enum Attempt
  Done(Compiled)
  Stale(List[String])
  Refused(Problems.Problem)
end

# The text of a file and the line of the session that each of its lines comes from.
struct Gen
  lines: List[String]
  origins: List[Int]
end

def over(settings: Env.Settings, file: String, text: String) -> Env.Settings
  buffer = Overlay.buffer(settings.workspace, settings.env.windows, file, SourceFile.Read.Text(text))
  settings.with(workspace: Overlay.over(settings.workspace, [buffer]), unused: false)
end

# The items of an entry, or an entry that needs more lines: a problem past its last character that is not blank, a
# delimiter or heredoc still open, or a doc comment with nothing after it.
def items_of(session: Session, text: String) -> Items
  end_at = content_end(text)
  case Lexer.lex(text)
    Diag.Outcome.Failed(found) ->
      return Items.Incomplete if found.span.start.offset >= end_at or OPEN_CODES.include?(found.code)

      Items.Failed(entry_problem(session, found.code, found.message, found.span, found.help))
    Diag.Outcome.Done(tokens) ->
      kinds = tokens.map { |token: Tokens.Token| token.kind }.filter { |kind: String| kind != "NL" and kind != "EOF" }
      return Items.Incomplete if kinds.size > 0 and kinds[kinds.size - 1] == "DOC"

      reserved = tokens.filter { |token: Tokens.Token| reserved?(token) }
      if reserved.size > 0
        message = "#{reserved[0].lexeme} is a name that the session keeps for itself"
        return Items.Failed(entry_problem(session, "REPL-RESERVED-NAME", message, reserved[0].span, Diag.Help.NoHelp))
      end

      case Parser.parse_entry(tokens, 0)
        Diag.Outcome.Failed(found) ->
          return Items.Incomplete if found.span.start.offset >= end_at

          Items.Failed(entry_problem(session, found.code, found.message, found.span, found.help))
        Diag.Outcome.Done(items) -> Items.Found(items)
      end
  end
end

# The offset after the last character of `text` that is not blank.
def content_end(text: String) -> Int
  at = text.length
  while at > 0 and BLANKS.include?(text.slice(at - 1, 1))
    at -= 1
  end

  at
end

# The names of the code that the session writes around an entry, which an entry cannot use.
def reserved?(token: Tokens.Token) -> Bool
  return false if token.kind != "name" and token.kind != "type-name"

  RESERVED.any? { |prefix: String| token.lexeme.start_with?(prefix) }
end

# The text with its `private` line blank: the line that holds the name `private` alone, as the parser takes it.
def public_text(text: String) -> String
  case Lexer.lex(text)
    Diag.Outcome.Failed(_) -> text
    Diag.Outcome.Done(tokens) ->
      lines = text.split("\n")
      at = 0
      for token in tokens
        before = at == 0 or tokens[at - 1].kind == "NL"
        after = at + 1 >= tokens.size or tokens[at + 1].kind == "NL" or tokens[at + 1].kind == "EOF"
        if token.kind == "name" and token.lexeme == "private" and before and after
          lines = lines.set(token.span.start.line - 1, "")
        end

        at += 1
      end

      lines.join("\n")
  end
end

# A problem of the entry's own text, whose lines start after the session's.
def entry_problem(
  session: Session,
  code: String,
  message: String,
  span: Source.Span,
  help: Diag.Help,
) -> Problems.Problem
  moved_problem(session, Problems.problem(session.file, "", code, message, span, help))
end

# An entry is compiled with every name of the session first. A name whose type was declared again holds values of the
# old type: the image tells which (`Attempt.Stale`), and the entry is compiled again without them. An entry that
# declares a type and does not check may fail only for such a name (`p.y` of a P that gained y): its declarations
# alone tell which names hold an old type (`stale_names`), and without any the first problem stands.
def compile_items(session: Session, text: String, items: List[Parser.EntryItem], settings: Env.Settings) -> Compiled
  dropped: List[String] = []
  tries = 0
  # Each try drops at least one more name.
  while tries <= session.bindings.size
    tries += 1
    case attempt(session, text, items, dropped, settings)
      Attempt.Done(compiled) -> return compiled
      Attempt.Stale(names) -> dropped = dropped.concat(names)
      Attempt.Refused(problem) ->
        stale = stale_names(session, text, items, dropped, settings)
        return Compiled.Failed(problem) if stale.size == 0

        dropped = dropped.concat(stale)
    end
  end

  Compiled.Failed(session_problem(session, "REPL-INTERNAL", "an entry did not settle its names"))
end

# The names that hold a type the entry's declarations change: the declarations are compiled alone, without the names
# whose types are structs or enums, and a name is stale when the entries of its types are not the current ones after
# that. None when the entry declares no type or its declarations do not compile.
def stale_names(
  session: Session,
  text: String,
  items: List[Parser.EntryItem],
  dropped: List[String],
  settings: Env.Settings,
) -> List[String]
  return [] if items.flat_map(&type_declared).size == 0

  typed = session.bindings.filter { |binding: Binding| !dropped.include?(binding.name) and binding.entries.size > 0 }
  return [] if typed.size == 0

  declarations = items.filter { |item: Parser.EntryItem| item.declaration.some? }
  aside = dropped.concat(typed.map { |binding: Binding| binding.name })
  case attempt(session, text, declarations, aside, settings)
    Attempt.Done(compiled) ->
      case compiled
        Compiled.Run(request) ->
          typed.filter { |binding: Binding| !current?(binding, request.ran.image) }
            .map do |binding: Binding| binding.name end

        _ -> []
      end

    Attempt.Stale(names) -> names
    Attempt.Refused(_) -> []
  end
end

def attempt(
  session: Session,
  text: String,
  items: List[Parser.EntryItem],
  dropped: List[String],
  settings: Env.Settings,
) -> Attempt
  plan = planned(session, text, items, dropped, session.entries + 1)
  case first_check(session, plan, settings)
    Checks.Failed(problem) -> Attempt.Refused(problem)
    Checks.Done(found) -> second(session, text, plan, found, settings)
  end
end

# The struct or enum that an item declares, by the name it has in the session's file.
def type_declared(item: Parser.EntryItem) -> List[String]
  case item.declaration
    some(decl) ->
      case Declarations.unwrap(decl)
        Ast.Decl.Struct(node) -> [node.name]
        Ast.Decl.Enum(node) -> [node.name]
        _ -> []
      end

    none -> []
  end
end

# The plan of an entry. A name rebound with a type (`x: String = ...`) at the top level of the entry is no parameter:
# the entry gives it its new type.
def planned(session: Session, text: String, items: List[Parser.EntryItem], dropped: List[String], number: Int) -> Plan
  first = session.lines
  lines = text.split("\n")
  added: List[Piece] = []
  statements: List[Piece] = []
  annotated: Set[String] = Set.new([])
  for item in items
    piece = piece_of(item, lines, first, session.folder)
    case item.declaration
      some(_) -> added = added.push(piece)
      none ->
        statements = statements.push(piece)
        case item.statement.unwrap!
          Ast.Stmt.Binding(node) ->
            if node.type.some?
              annotated = annotated.add(node.name)
            end

          _ -> annotated = annotated
        end
    end
  end

  replaced = Set.new(added.map { |piece: Piece| piece.name }.filter { |name: String| name != "" })
  imports = Set.new(session.pieces.filter { |piece: Piece| piece.name == "" }.map { |piece: Piece| piece.key })
  kept = session.pieces.filter { |piece: Piece| !replaced.include?(piece.name) }
  fresh = added.filter { |piece: Piece| piece.name != "" or !imports.include?(piece.key) }
  params = session.bindings.filter do |binding: Binding|
    !annotated.include?(binding.name) and !dropped.include?(binding.name)
  end

  shows = false
  if items.size > 0
    last = items[items.size - 1]
    case last.statement
      some(statement) ->
        case statement
          Ast.Stmt.Expression(_) -> shows = true
          _ -> shows = false
        end

      none -> shows = false
    end
  end

  declared = added.map { |piece: Piece| piece.name }.filter { |name: String| name != "" }
  Plan(
    number: number,
    pieces: kept.concat(fresh),
    statements: statements,
    params: params,
    declared: declared,
    dropped: dropped,
    shows: shows,
  )
end

# The lines of an item, which starts on line `span.start.line` of the entry, after `before` lines of the session. An
# import of a file from `folder` names it from the session's folder.
def piece_of(item: Parser.EntryItem, lines: List[String], before: Int, folder: String) -> Piece
  span = item.span
  text = lines.drop(span.start.line - 1).take(span.stop.line - span.start.line + 1).join("\n")
  line = before + span.start.line
  case item.declaration
    some(decl) ->
      Piece(
        name: Declarations.name_of(decl),
        text: imported_from(text, decl, folder),
        line: line,
        rank: rank_of(decl),
        key: import_key(decl, folder, text),
      )
    none -> Piece(name: "", text: text, line: line)
  end
end

# What an import imports: its path from the session's folder with the `.` and `..` parts folded, and its alias or
# names. Any other declaration is its text.
def import_key(decl: Ast.Decl, folder: String, text: String) -> String
  case Declarations.unwrap(decl)
    Ast.Decl.Import(node) ->
      path = node.path
      if folder != "" and !path.start_with?("std/") and !path.start_with?("pkg/")
        path = Paths.join(folder, path)
      end

      names = node.names.map { |entry: Ast.ImportName| "#{entry.name} as #{entry.local}" }.join(",")
      "#{normal_path(path)}|#{Declarations.alias_of(node)}|#{names}"
    _ -> text
  end
end

def normal_path(path: String) -> String
  kept: List[String] = []
  for part in path.split("/")
    if part == ".." and kept.size > 0 and kept[kept.size - 1] != ".."
      kept = kept.take(kept.size - 1)
    elsif part != "." and part != ""
      kept = kept.push(part)
    end
  end

  kept.join("/")
end

def imported_from(text: String, decl: Ast.Decl, folder: String) -> String
  return text if folder == ""

  case Declarations.unwrap(decl)
    Ast.Decl.Import(node) ->
      return text if node.path.start_with?("std/") or node.path.start_with?("pkg/")

      text.replace("\"#{node.path}\"", "\"#{Paths.join(folder, node.path)}\"")
    _ -> text
  end
end

def entry_name(plan: Plan) -> String = "#{ENTRY}#{plan.number}"

def record_name(plan: Plan) -> String = "#{RECORD}#{plan.number}"

def param_text(plan: Plan) -> String
  plan.params.map { |binding: Binding| "#{binding.name}: #{binding.type}" }.join(", ")
end

def rank_of(decl: Ast.Decl) -> Int
  case Declarations.unwrap(decl)
    Ast.Decl.Import(_) -> 0
    Ast.Decl.Reexport(_) -> 0
    Ast.Decl.Constant(_) -> 1
    Ast.Decl.Function(_) -> 3
    _ -> 2
  end
end

# The declarations of the file of `ranks` in the order a file takes them, each followed by a blank line.
def declarations(gen: Gen, plan: Plan, ranks: List[Int]) -> Gen
  out = gen
  for rank in ranks
    for piece in plan.pieces
      if piece.rank == rank
        out = add_text(out, piece.text, piece.line)
        out = add_line(out, "", piece.line + piece.text.split("\n").size - 1)
      end
    end
  end

  out
end

def empty_gen() -> Gen = Gen(lines: [], origins: [])

# Lines that the user typed, from the session's line `line` on.
def add_text(gen: Gen, text: String, line: Int) -> Gen
  out = gen
  at = line
  for part in text.split("\n")
    out = Gen(lines: out.lines.push(part), origins: out.origins.push(at))
    at += 1
  end

  out
end

# A line the session writes, which stands at the session's line `line`: its origin is negative, so a span on it moves
# to the start of that line (its columns are not the user's).
def add_line(gen: Gen, text: String, line: Int) -> Gen
  Gen(lines: gen.lines.push(text), origins: gen.origins.push(-line))
end

def gen_text(gen: Gen) -> String = gen.lines.join("\n") + "\n"

def origin_map(gen: Gen) -> Map[Int, Int]
  lines: Map[Int, Int] = {}
  at = 1
  for origin in gen.origins
    lines = lines.put(at, origin)
    at += 1
  end

  lines
end

# The first check: the entry's statements in a function that returns nothing. A last expression that the checker
# refuses to drop (a pure call, a Result) is checked again, discarded with `_ =`, which a Void one could not be.
def first_check(session: Session, plan: Plan, settings: Env.Settings) -> Checks
  checked = checked_once(session, plan, settings, false)
  case checked
    Checks.Failed(problem) ->
      if plan.shows and (problem.code == "CHECK-UNUSED-VALUE" or problem.code == "CHECK-UNUSED-RESULT")
        return checked_once(session, plan, settings, true)
      end

      checked
    Checks.Done(_) -> checked
  end
end

def checked_once(session: Session, plan: Plan, settings: Env.Settings, discard: Bool) -> Checks
  line = session.lines + 1
  gen = declarations(empty_gen(), plan, [0, 1, 2, 3])
  gen = add_line(gen, "def #{entry_name(plan)}(#{param_text(plan)}) -> Void", line)
  at = 0
  for statement in plan.statements
    if discard and at == plan.statements.size - 1
      gen = wrapped(gen, "_ = (", statement, ")")
    else
      gen = add_text(gen, statement.text, statement.line)
    end

    at += 1
  end

  gen = add_line(gen, "end", line)
  case Front.query_file(session.file, over(settings, session.file, gen_text(gen)))
    Front.Outcome.Rejected(problem) -> Checks.Failed(mapped_problem(session, problem, gen))
    Front.Outcome.Done(front) -> Checks.Done(found_in(session, plan, front, gen_text(gen)))
  end
end

# The lines of a statement between a line before it and one after it, which the session writes.
def wrapped(gen: Gen, before: String, statement: Piece, after: String) -> Gen
  out = add_line(gen, before, statement.line)
  out = add_text(out, statement.text, statement.line)
  add_line(out, after, statement.line + statement.text.split("\n").size - 1)
end

# The type of the shown value and the names the entry binds, with their types: a name of the session keeps its type,
# and a new one, or one rebound with a type, has the type the checker gave its value (or the type written). A name
# whose type cannot be written (it holds Unknown) is not kept.
def found_in(session: Session, plan: Plan, front: Front.Checked, text: String) -> Found
  written = TypeAt.written_prefixes(front.linked)
  types = front.checked.types
  body = entry_body(front, entry_name(plan))
  shown = ""
  if plan.shows and body.size > 0
    value = last_value(body[body.size - 1])
    if value.some?
      type = types[Ast.expr_id(value.unwrap!)]
      if !T.is?(type, "Void") and !T.is?(type, "Unknown")
        shown = T.to_text_as(type, written)
      end
    end
  end

  bindings = plan.params
  slot = session.slots
  for statement in body
    case statement
      Ast.Stmt.Binding(node) ->
        known = node.name == "_" or bindings.any? { |binding: Binding| binding.name == node.name }
        if !known
          value_type = types[Ast.expr_id(node.value)]
          bound = front.checked.bound.get(node.id, [])
          if bound.size > 0
            value_type = bound[0]
          end

          type = T.to_text_as(value_type, written)
          if node.type.some?
            span = node.type.unwrap!.span
            type = text.slice(span.start.offset, span.stop.offset - span.start.offset)
          end

          if !type.include?("Unknown") and !T.debug_text(value_type).include?("Unknown")
            old = session.bindings.filter { |binding: Binding| binding.name == node.name }
            number = slot
            if old.size > 0
              number = old[0].slot
            else
              slot += 1
            end

            bindings = bindings.push(Binding(name: node.name, type: type, slot: number, types: names_in(value_type)))
          end
        end

      _ -> next
    end
  end

  Found(shown: shown, bindings: bindings)
end

def entry_body(front: Front.Checked, name: String) -> List[Ast.Stmt]
  for decl in front.linked.modules[0].declarations
    case Declarations.unwrap(decl)
      Ast.Decl.Function(node) -> return node.body if node.name == name

      _ -> next
    end
  end

  []
end

def last_value(statement: Ast.Stmt) -> Optional[Ast.Expr]
  case statement
    Ast.Stmt.Expression(node) -> some(node.value)
    Ast.Stmt.Return(node) -> node.value
    Ast.Stmt.Binding(node) ->
      return some(node.value) if node.name == "_"

      none
    _ -> none
  end
end

# The second check, which builds what the child runs: the entry's function returns a struct of the value to show and
# of every name. A new name whose type the session's file cannot write (a type private to an imported file) is not
# kept, and a value to show of such a type is shown by its text.
def second(session: Session, text: String, plan: Plan, found: Found, settings: Env.Settings) -> Attempt
  second_with(session, text, plan, found, settings, false)
end

def second_with(
  session: Session,
  text: String,
  plan: Plan,
  found: Found,
  settings: Env.Settings,
  inspected: Bool,
) -> Attempt
  line = session.lines + 1
  record = record_name(plan)
  gen = declarations(empty_gen(), plan, [0, 1, 2])
  shown_type = found.shown
  if shown_type == "" or shown_type == "String" or inspected
    shown_type = "String"
  end

  gen = add_line(gen, "struct #{record}", line)
  gen = add_line(gen, "  #{SHOWN}: #{shown_type}", line)
  shown_line = gen.lines.size
  fields: Map[Int, String] = {}
  at = 0
  for binding in found.bindings
    gen = add_line(gen, "  #{binding.name}: #{binding.type}", line)
    if at >= plan.params.size
      fields = fields.put(gen.lines.size, binding.name)
    end

    at += 1
  end

  gen = add_line(gen, "end", line)
  gen = add_line(gen, "", line)
  gen = declarations(gen, plan, [3])
  gen = add_line(gen, "def #{entry_name(plan)}(#{param_text(plan)}) -> #{record}", line)
  value = "\"\""
  at = 0
  for statement in plan.statements
    last = at == plan.statements.size - 1
    if last and found.shown != ""
      closing = ")"
      if found.shown == "String" or inspected
        closing = ").inspect"
      end

      gen = wrapped(gen, "#{SHOWN} = (", statement, closing)
      value = SHOWN
    else
      gen = add_text(gen, statement.text, statement.line)
    end

    at += 1
  end

  values = found.bindings.map { |binding: Binding| "#{binding.name}: #{binding.name}" }
  gen = add_line(gen, "#{record}(#{[SHOWN + ": " + value].concat(values).join(", ")})", line)
  gen = add_line(gen, "end", line)
  case Front.query_file(session.file, over(settings, session.file, gen_text(gen)))
    Front.Outcome.Rejected(problem) ->
      if session_file?(session, problem.file)
        unwritten = fields.get(problem.span.start.line)
        if unwritten.some?
          kept = found.bindings.filter { |binding: Binding| binding.name != unwritten.unwrap! }
          skipped = found.skipped.push(unwritten.unwrap!)
          return second_with(session, text, plan, found.with(bindings: kept, skipped: skipped), settings, inspected)
        end

        if problem.span.start.line == shown_line and !inspected and found.shown != ""
          return second_with(session, text, plan, found, settings, true)
        end
      end

      Attempt.Refused(mapped_problem(session, problem, gen))
    Front.Outcome.Done(front) -> built(session, text, plan, found, front, gen, settings)
  end
end

def built(
  session: Session,
  text: String,
  plan: Plan,
  found: Found,
  front: Front.Checked,
  gen: Gen,
  settings: Env.Settings,
) -> Attempt
  case Lowering.lower_from(front.linked, front.checked, [entry_name(plan)])
    Lowering.Lowered.Failed(problem) -> Attempt.Refused(mapped_problem(session, problem, gen))
    Lowering.Lowered.Done(program) ->
      after = typed(session, text)
      merged = Image.merge(
        session.image,
        program,
        entry_name(plan),
        front.linked.modules[0].file,
        after.text,
        origin_map(gen),
        session.lines + 1,
        references(front.linked),
      )

      if merged.clash != ""
        name = T.display_name(merged.clash)
        message = "#{name} was a struct in this session; :reset to declare an enum of that name"
        return Attempt.Refused(session_problem(session, "REPL-KIND-CHANGE", message))
      end

      stale = plan.params.filter { |binding: Binding| !current?(binding, merged.ran) }
      return Attempt.Stale(stale.map { |binding: Binding| binding.name }) if stale.size > 0

      over = Writer.write_over(merged.program, settings.version, session.image.tables)
      case over.written
        Writer.Written.Failed(problem) -> Attempt.Refused(problem)
        Writer.Written.Done(bytes) ->
          ran = Image.written(merged.ran, merged.program, over.tables)
          loaded = Image.written(merged.loaded, merged.program, over.tables)
          bindings = (
            found.bindings
              .take(plan.params.size)
              .concat(found.bindings.drop(plan.params.size).map { |binding: Binding| with_entries(binding, ran) })
          )

          names = Set.new(bindings.map { |binding: Binding| binding.name })
          top = session.slots
          for binding in bindings
            if binding.slot + 1 > top
              top = binding.slot + 1
            end
          end

          kept = session.bindings.filter { |binding: Binding|
            !names.include?(binding.name) and !plan.dropped.include?(binding.name)
          }

          Attempt.Done(
            Compiled.Run(
              Request(
                bytes: bytes,
                entry: merged.entry,
                reads: plan.params.map { |binding: Binding| binding.slot },
                writes: bindings.map { |binding: Binding| binding.slot },
                shown: found.shown,
                bound: bindings.drop(plan.params.size),
                declared: plan.declared,
                dropped: plan.dropped,
                skipped: found.skipped,
                ran: after.with(
                  pieces: plan.pieces,
                  bindings: kept.concat(bindings),
                  entries: plan.number,
                  slots: top,
                  image: ran,
                ),
                loaded: after.with(entries: plan.number, image: loaded),
              ),
            ),
          )
      end
  end
end

def with_entries(binding: Binding, image: Image.Image) -> Binding
  binding.with(entries: Image.entries(image, binding.types))
end

# Whether the types a name holds values of are still the current ones of their names.
def current?(binding: Binding, image: Image.Image) -> Bool
  now = Image.entries(image, binding.entries.keys)
  return false if now.size != binding.entries.size

  binding.entries.keys.all? { |name: String| now[name] == binding.entries[name] }
end

# The structs and enums a type names.
def names_in(type: T.Type) -> List[String]
  inner = T.args(type).flat_map(&names_in)
  case type
    T.Type.Struct(name, _) -> inner.push(name)
    T.Type.Enum(name, _) -> inner.push(name)
    T.Type.Map(key, value) -> names_in(key).concat(names_in(value))
    T.Type.ATS(key, value) -> names_in(key).concat(names_in(value))
    T.Type.Fn(params, result) -> params.flat_map(&names_in).concat(names_in(result))
    T.Type.Opaque(_) -> []
    T.Type.Var(_) -> []
    _ -> inner_names(type)
  end
end

def inner_names(type: T.Type) -> List[String]
  case type
    T.Type.Result(item) -> names_in(item)
    T.Type.Optional(item) -> names_in(item)
    T.Type.Task(item) -> names_in(item)
    T.Type.Channel(item) -> names_in(item)
    T.Type.Address(item) -> names_in(item)
    T.Type.Lazy(item) -> names_in(item)
    T.Type.Codec(item) -> names_in(item)
    T.Type.List(item) -> names_in(item)
    T.Type.Set(item) -> names_in(item)
    _ -> []
  end
end

# For each struct and enum of the program's files, the types its fields or payloads name, through type aliases.
def references(linked: Linker.Linked) -> Map[String, List[String]]
  aliases: Map[String, Ast.TypeRef] = {}
  for module in linked.modules
    for decl in module.declarations
      case Declarations.unwrap(decl)
        Ast.Decl.TypeAlias(node) -> aliases = aliases.put(node.name, node.target)
        _ -> next
      end
    end
  end

  refs: Map[String, List[String]] = {}
  for module in linked.modules
    for decl in module.declarations
      case Declarations.unwrap(decl)
        Ast.Decl.Struct(node) ->
          refs = refs.put(node.name, node.fields.flat_map { |field: Ast.FieldDecl| ref_names(field.type, aliases, 0) })
        Ast.Decl.Enum(node) ->
          payloads = node.variants.flat_map { |variant: Ast.EnumVariant| variant.payload_types }
          refs = refs.put(node.name, payloads.flat_map { |ref: Ast.TypeRef| ref_names(ref, aliases, 0) })
        _ -> next
      end
    end
  end

  refs
end

# The names a written type names, each alias with the names of what it stands for (at most 64 aliases deep).
def ref_names(ref: Ast.TypeRef, aliases: Map[String, Ast.TypeRef], depth: Int) -> List[String]
  inner = ref.args.flat_map { |arg: Ast.TypeRef| ref_names(arg, aliases, depth) }.push(ref.name)
  target = aliases.get(ref.name)
  return inner if target.none? or depth >= 64

  inner.concat(ref_names(target.unwrap!, aliases, depth + 1))
end

# The problem of the file at the lines of the session; a problem of an imported file stays as it is. The function
# that the session writes around an entry is not named.
def mapped_problem(session: Session, problem: Problems.Problem, gen: Gen) -> Problems.Problem
  return problem if !session_file?(session, problem.file)

  lines = origin_map(gen)
  fallback = session.lines + 1
  labels = problem.labels.map { |label: Problems.Label| label.with(span: mapped_span(label.span, lines, fallback)) }
  placed(session, problem.with(span: mapped_span(problem.span, lines, fallback), labels: labels))
end

# A problem at lines of the session, in the file that `:load` entered them from when it did.
def placed(session: Session, problem: Problems.Problem) -> Problems.Problem
  out = problem
  if out.signature.start_with?(ENTRY)
    out = out.with(signature: "")
  end

  line = out.span.start.line
  for load in session.loads
    if line >= load.first and line < load.first + load.count
      shift = load.first - 1
      labels = out.labels.map { |label: Problems.Label| label.with(span: shifted(label.span, shift)) }
      return out.with(file: load.file, span: shifted(out.span, shift), labels: labels)
    end
  end

  out
end

def shifted(span: Source.Span, shift: Int) -> Source.Span
  Source.Span(
    start: span.start.with(line: span.start.line - shift),
    stop: span.stop.with(line: span.stop.line - shift),
  )
end

def mapped_span(span: Source.Span, lines: Map[Int, Int], fallback: Int) -> Source.Span
  Image.moved_span(span, lines, fallback)
end

# A problem of the entry's own text, whose lines start after the session's.
def moved_problem(session: Session, problem: Problems.Problem) -> Problems.Problem
  placed(session, problem.with(span: shifted(problem.span, -session.lines)))
end

# A problem of the session at the first line of the entry.
def session_problem(session: Session, code: String, message: String) -> Problems.Problem
  start = Source.Position(offset: 0, line: session.lines + 1, column: 1)
  span = Source.Span(start: start, stop: start)
  placed(session, Problems.problem(session.file, "", code, message, span, Diag.Help.NoHelp))
end

def not_expression(session: Session, text: String) -> Problems.Problem
  start = Source.Position(offset: 0, line: session.lines + 1, column: 1)
  stop = Source.Position(offset: text.length, line: session.lines + 1, column: text.split("\n")[0].length + 1)
  Problems.problem(
    session.file,
    "",
    "REPL-USAGE",
    ":type takes an expression",
    Source.Span(start: start, stop: stop),
    Diag.Help.NoHelp,
  )
end
