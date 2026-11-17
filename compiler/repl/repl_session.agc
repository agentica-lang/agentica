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
import Env from "../modules/link_env"
import Overlay from "../modules/overlay"
import TypeAt from "../query/type_at"
import Ast from "../syntax/ast"
import Lexer from "../syntax/lexer"
import Parser from "../syntax/parser"
import Source from "../syntax/source"
import SourceFile from "../syntax/source_file"
import T from "../syntax/types"
import Image from "repl_image"

## A name of the session: its type as the session's file writes it and the slot of the child that holds its value.
struct Binding
  name: String
  type: String
  slot: Int
end

## A declaration of the session: the name it declares ("" for an import), its text, its first line and its rank in a
## file: imports, constants, types, then functions.
struct Piece
  name: String
  text: String
  line: Int
  rank: Int = 3
end

## The session. `file` is the path of its virtual file, `text` every line typed so far, `lines` their number, `slots`
## the number of slots of the child in use, and `image` what the child holds.
struct Session
  file: String
  pieces: List[Piece]
  bindings: List[Binding]
  text: String
  lines: Int
  entries: Int
  slots: Int
  image: Image.Image
end

## The first program of a session, which serves the entries, and the session that has only it.
enum Started
  Ready(Session, Bytes)
  Failed(Problems.Problem)
end

## What the child is sent for an entry: the program (empty when the child has it already), the number of the entry
## function, the slots it reads and writes, the type of the value it shows ("" for none), the names it binds anew or
## with a new type, the names it declares, and the names whose struct or enum it declared again, which the session
## drops. `ran` is the session after the entry, and `loaded` the one
## after a failure of it, when the child has the program but not the declarations and names of the entry.
struct Request
  bytes: Bytes
  entry: Int
  reads: List[Int]
  writes: List[Int]
  shown: String
  bound: List[Binding]
  declared: List[String]
  dropped: List[String]
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
  session.with(text: session.text + text + "\n", lines: session.lines + text.split("\n").size)
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

## The names of the session that a struct, an enum or a type alias of `names` appears in the type of.
def mentioning(bindings: List[Binding], names: List[String]) -> List[String]
  found: List[String] = []
  for binding in bindings
    words = Set.new(binding.type.replace("[", " ").replace("]", " ").replace(",", " ").replace(".", " ").split(" "))
    if (names.any? { |name: String| words.include?(name) })
      found = found.push(binding.name)
    end
  end

  found
end

private

# The base of every session: main serves the entries.
SERVE = "def main() -> Void\n  FrontEnd.serve_session()\nend\n"
# The problems of the lexer that the next lines may close: a delimiter or a heredoc still open at the end.
OPEN_CODES = ["LEX-UNCLOSED-DELIMITER", "LEX-UNTERMINATED-HEREDOC"]
# The field of the value the entry shows.
SHOWN = "repl_shown_"

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
end

enum Checks
  Done(Found)
  Failed(Problems.Problem)
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

def items_of(session: Session, text: String) -> Items
  first = session.lines
  end_at = text.strip.length
  case Lexer.lex(text)
    Diag.Outcome.Failed(found) ->
      return Items.Incomplete if found.span.start.offset >= end_at or OPEN_CODES.include?(found.code)

      Items.Failed(
        moved_problem(Problems.problem(session.file, "", found.code, found.message, found.span, found.help), first),
      )
    Diag.Outcome.Done(tokens) ->
      case Parser.parse_entry(tokens, 0)
        Diag.Outcome.Failed(found) ->
          return Items.Incomplete if found.span.start.offset >= end_at

          Items.Failed(
            moved_problem(
              Problems.problem(session.file, "", found.code, found.message, found.span, found.help),
              first,
            ),
          )
        Diag.Outcome.Done(items) -> Items.Found(items)
      end
  end
end

def compile_items(session: Session, text: String, items: List[Parser.EntryItem], settings: Env.Settings) -> Compiled
  number = session.entries + 1
  lines = text.split("\n")
  retyped: List[String] = []
  for item in items
    piece = piece_of(item, lines, session.lines)
    changed = session.pieces.any? { |old: Piece| old.rank == 2 and old.name == piece.name and old.text != piece.text }
    if item.declaration.some? and changed
      retyped = retyped.push(piece.name)
    end
  end

  dropped = mentioning(session.bindings, retyped)
  plan = planned(session, text, items, dropped, number)
  case first_check(session, plan, settings)
    Checks.Failed(problem) -> Compiled.Failed(problem)
    Checks.Done(found) -> second(session, text, plan, found, settings)
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
    piece = piece_of(item, lines, first)
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
  imports = Set.new(session.pieces.filter { |piece: Piece| piece.name == "" }.map { |piece: Piece| piece.text })
  kept = session.pieces.filter { |piece: Piece| !replaced.include?(piece.name) }
  fresh = added.filter { |piece: Piece| piece.name != "" or !imports.include?(piece.text) }
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

# The lines of an item, which starts on line `span.start.line` of the entry, after `before` lines of the session.
def piece_of(item: Parser.EntryItem, lines: List[String], before: Int) -> Piece
  span = item.span
  text = lines.drop(span.start.line - 1).take(span.stop.line - span.start.line + 1).join("\n")
  line = before + span.start.line
  case item.declaration
    some(decl) -> Piece(name: Declarations.name_of(decl), text: text, line: line, rank: rank_of(decl))
    none -> Piece(name: "", text: text, line: line)
  end
end

def entry_name(plan: Plan) -> String = "repl_entry_#{plan.number}"

def record_name(plan: Plan) -> String = "ReplEntry#{plan.number}"

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
        out = add_line(out, "", piece.line)
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
          type = T.to_text_as(types[Ast.expr_id(node.value)], written)
          if node.type.some?
            span = node.type.unwrap!.span
            type = text.slice(span.start.offset, span.stop.offset - span.start.offset)
          end

          if !type.include?("Unknown")
            old = session.bindings.filter { |binding: Binding| binding.name == node.name }
            number = slot
            if old.size > 0
              number = old[0].slot
            else
              slot += 1
            end

            bindings = bindings.push(Binding(name: node.name, type: type, slot: number))
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
# of every name.
def second(session: Session, text: String, plan: Plan, found: Found, settings: Env.Settings) -> Compiled
  line = session.lines + 1
  record = record_name(plan)
  gen = declarations(empty_gen(), plan, [0, 1, 2])
  shown_type = found.shown
  if shown_type == "" or shown_type == "String"
    shown_type = "String"
  end

  gen = add_line(gen, "struct #{record}", line)
  gen = add_line(gen, "  #{SHOWN}: #{shown_type}", line)
  for binding in found.bindings
    gen = add_line(gen, "  #{binding.name}: #{binding.type}", line)
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
      if found.shown == "String"
        closing = ").inspect"
      end

      gen = wrapped(gen, "#{SHOWN} = (", statement, closing)
      value = SHOWN
    else
      gen = add_text(gen, statement.text, statement.line)
    end

    at += 1
  end

  fields = found.bindings.map { |binding: Binding| "#{binding.name}: #{binding.name}" }
  gen = add_line(gen, "#{record}(#{[SHOWN + ": " + value].concat(fields).join(", ")})", line)
  gen = add_line(gen, "end", line)
  case Front.query_file(session.file, over(settings, session.file, gen_text(gen)))
    Front.Outcome.Rejected(problem) -> Compiled.Failed(mapped_problem(session, problem, gen))
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
) -> Compiled
  case Lowering.lower_from(front.linked, front.checked, [entry_name(plan)])
    Lowering.Lowered.Failed(problem) -> Compiled.Failed(mapped_problem(session, problem, gen))
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
      )

      over = Writer.write_over(merged.program, settings.version, session.image.tables)
      case over.written
        Writer.Written.Failed(problem) -> Compiled.Failed(problem)
        Writer.Written.Done(bytes) ->
          ran = Image.written(merged.ran, merged.program, over.tables)
          loaded = Image.written(merged.loaded, merged.program, over.tables)
          names = Set.new(found.bindings.map { |binding: Binding| binding.name })
          top = session.slots
          for binding in found.bindings
            if binding.slot + 1 > top
              top = binding.slot + 1
            end
          end

          kept = session.bindings.filter { |binding: Binding|
            !names.include?(binding.name) and !plan.dropped.include?(binding.name)
          }

          Compiled.Run(
            Request(
              bytes: bytes,
              entry: merged.entry,
              reads: plan.params.map { |binding: Binding| binding.slot },
              writes: found.bindings.map { |binding: Binding| binding.slot },
              shown: found.shown,
              bound: found.bindings.drop(plan.params.size),
              declared: plan.declared,
              dropped: plan.dropped,
              ran: after.with(
                pieces: plan.pieces,
                bindings: kept.concat(found.bindings),
                entries: plan.number,
                slots: top,
                image: ran,
              ),
              loaded: after.with(entries: plan.number, image: loaded),
            ),
          )
      end
  end
end

# The problem of the file at the lines of the session; a problem of an imported file stays as it is.
def mapped_problem(session: Session, problem: Problems.Problem, gen: Gen) -> Problems.Problem
  return problem if !session_file?(session, problem.file)

  lines = origin_map(gen)
  fallback = session.lines + 1
  labels = problem.labels.map { |label: Problems.Label| label.with(span: mapped_span(label.span, lines, fallback)) }
  problem.with(span: mapped_span(problem.span, lines, fallback), labels: labels)
end

def mapped_span(span: Source.Span, lines: Map[Int, Int], fallback: Int) -> Source.Span
  Source.Span(start: Image.moved(span.start, lines, fallback), stop: Image.moved(span.stop, lines, fallback))
end

# A problem of the entry's own text, whose lines start after the session's.
def moved_problem(problem: Problems.Problem, before: Int) -> Problems.Problem
  span = problem.span
  start = span.start.with(line: span.start.line + before)
  stop = span.stop.with(line: span.stop.line + before)
  problem.with(span: Source.Span(start: start, stop: stop))
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
