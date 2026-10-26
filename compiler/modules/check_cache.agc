## The cache of checked modules of `agentica check` and `agentica type-at` (issue #630). A module that was checked once
## and did not change, with everything it imports, is not checked again, and its file is not lexed and parsed in full
## again either. The machine keeps one entry for each file of a program (io/check_cache.agc, `Workspace.CheckCache`);
## this file decides what an entry says and when it may be used, and does no I/O.
##
## An entry holds four things about the text of one file: its SHA-256, the tree digest at which the file passed a check
## (`tree`), the stub, and the type of each of its constants (type_code.agc). The tree digest is the SHA-256 of the
## text, of the shape of the file (the package it belongs to and the names its imports bind) and of the tree digests of
## the files it imports, so it changes when the file or anything under it changes. A module whose tree digest is the
## one its entry vouches for, and whose constants the entry types, is `clean`: every function body and constant in it
## passed the check of that tree, and a new check of the same tree gives the same result, since a body is checked from
## the text of its module and the declarations and constants of what it imports and nothing else. The checker skips
## the bodies, constants and field defaults of the clean modules (`Checker.check_query_taking`) and reads the types of
## their constants from the entry.
##
## The stub is the text of the file with the statements of every function body, and the value of every long constant,
## blanked. It has the same length, line breaks and offsets, so every span of a declaration is the one the whole text
## gives, and it lexes and parses much faster than the text. The loader parses the stub of a file whose text digest an
## entry holds, in place of the text (Modules.load_checked); the module is then `stubbed`, and is used only while it is
## `clean`, since its bodies are not there to be checked. A stub is made from a parse of the text and is kept only
## after it parses again with the same declarations (`stub_of`). An entry that cannot be decoded, or that is for
## another text, is a miss; nothing here halts or gives a different diagnostic because of what an entry holds.

import Diag from "../diagnostics/diagnostic"
import Ast from "../syntax/ast"
import Lexer from "../syntax/lexer"
import Parser from "../syntax/parser"
import Declarations from "declarations"
import Workspace from "workspace"

# The first line of an entry and of every tree digest; change it when the meaning of an entry changes.
FORMAT = "agentica-check-2"

# The digest of a tree and of a text is 64 hex digits; an entry without a vouched tree holds this in its place.
DIGEST_CHARS = 64
NO_TREE = "0000000000000000000000000000000000000000000000000000000000000000"

# `end` closes a function; the stub keeps it and the line break before it.
END_WORD = "end"

# A constant whose value is shorter than this keeps its value in the stub: it is cheap to read and to check.
ELIDE_FROM = 24

# The digits of the length of the stub in an entry, at most.
SIZE_DIGITS = 12

# The longest line of the head that holds the length of the stub and its digest.
STUB_LINE_CHARS = 12 + 1 + 64

# The line of a constant in the tail of an entry: this word, the name and the type, with one space between.
CONSTANT_WORD = "const"

# Blanks for the stub, in pieces of this many.
BLANK_RUN = 128
BLANKS = (
  "                                                                " +
  "                                                                "
)

## What an entry says about the text whose digest was asked for: `tree` is "" when no check vouches for it, `stub` is
## "" when the entry has none, and `constants` holds the type of each constant of the file by its name, as
## type_code.agc writes it (all of them, or none).
export struct Entry
  tree: String
  stub: String
  constants: Map[String, String]
end

# A piece of the text to blank, from its first character to the one before `stop`; `wrap` makes it a parenthesized
# zero (a constant's value) instead of blanks (the statements of a body).
struct Cut
  first: Int
  stop: Int
  wrap: Bool
end

## The SHA-256 of `text` as 64 lowercase hex digits.
export def text_digest(text: String) -> String
  return hex(Crypto.sha256(String.to_bytes(text)))
end

## The tree digest of a file: `shape` (what describes it apart from its text), the digest of its text and the tree
## digests of the files it imports, in the order of its import lines.
export def tree_digest(shape: String, digest: String, imported: List[String]) -> String
  pieces = [FORMAT, shape, digest].concat(imported)
  return hex(Crypto.sha256(String.to_bytes(pieces.map do |text: String| piece(text) end.join(""))))
end

## Every piece is written with its length, so two different lists never give one text.
export def piece(text: String) -> String
  return "#{text.length}:#{text}"
end

## The names of the constants that `program` declares, sorted.
export def constant_names(program: Ast.Program) -> List[String]
  names: List[String] = []
  for wrapped in program.declarations
    case Declarations.unwrap(wrapped)
      Ast.Decl.Constant(node) -> names = names.push(node.name)
      _ -> next
    end
  end

  return names.sort
end

## The entry the cache holds for the file `key` if it is for the text with `digest`, else Absent.
export def find(cache: Workspace.CheckCache, key: String, digest: String) -> Ast.Optional[Entry]
  if !cache.on
    return Ast.Optional.Absent
  end

  raw = cache.read.call(key)
  if !raw.ok?
    return Ast.Optional.Absent
  end

  return decode(raw.unwrap!, digest)
end

## The text of an entry for the text with `digest`: four lines of head, the stub, then one line for each constant.
export def encode(digest: String, entry: Entry) -> String
  tree = entry.tree
  if tree == ""
    tree = NO_TREE
  end

  head = [FORMAT, "text #{digest}", "tree #{tree}", "stub #{entry.stub.length} #{text_digest(entry.stub)}"].join("\n")
  lines = entry.constants.keys.sort.map do |name: String|
    "\n#{CONSTANT_WORD} #{name} #{escaped(entry.constants[name])}"
  end

  return head + "\n" + entry.stub + lines.join("")
end

## Keeps the entry of the file `key` for the text with `digest`. False when the machine could not.
export def store(cache: Workspace.CheckCache, key: String, digest: String, entry: Entry) -> Bool
  if !cache.on
    return false
  end

  return cache.write.call(key, encode(digest, entry))
end

## The stub of `text`, which `program` is the parse of, or Absent when there is none worth keeping: nothing to blank,
## or the text does not have the shape the cut relies on, or the stub does not parse to the same declarations.
export def stub_of(text: String, program: Ast.Program) -> Ast.Optional[String]
  cuts = cuts_of(text, program.declarations)
  if !cuts.ok? or cuts.unwrap!.size == 0
    return Ast.Optional.Absent
  end

  pieces: List[String] = []
  at = 0
  for cut in cuts.unwrap!
    pieces = pieces.push(text.slice(at, cut.first - at))
    pieces = pieces.push(replacement(text.slice(cut.first, cut.stop - cut.first), cut.wrap))
    at = cut.stop
  end

  stub = pieces.push(text.slice(at, text.length - at)).join("")
  if stub.length == text.length and same_declarations?(program, stub)
    return Ast.Optional.Present(stub)
  end

  return Ast.Optional.Absent
end

# The entry in `raw` if it is well formed and for `digest`. Every length is looked at before a slice is taken: an entry
# is the content of a file that anyone who can write the folder may have changed.
def decode(raw: String, digest: String) -> Ast.Optional[Entry]
  head = "#{FORMAT}\ntext #{digest}\ntree "
  if !raw.starts_with?(head) or raw.length < head.length + DIGEST_CHARS + 1
    return Ast.Optional.Absent
  end

  tree = raw.slice(head.length, DIGEST_CHARS)
  rest = raw.slice(head.length + DIGEST_CHARS, raw.length - head.length - DIGEST_CHARS)
  if !rest.starts_with?("\nstub ")
    return Ast.Optional.Absent
  end

  after = rest.slice(6, rest.length - 6)
  at = after.index_of("\n")
  if !at.ok? or at.unwrap! > STUB_LINE_CHARS
    return Ast.Optional.Absent
  end

  sizes = after.slice(0, at.unwrap!).split(" ")
  if sizes.size != 2 or sizes[0].length > SIZE_DIGITS
    return Ast.Optional.Absent
  end

  size = sizes[0].to_i()
  start = at.unwrap! + 1
  if !size.ok? or size.unwrap! < 0 or start + size.unwrap! > after.length
    return Ast.Optional.Absent
  end

  # A stub that is not the one whose digest the entry holds was damaged, and the entry is dropped.
  stub = after.slice(start, size.unwrap!)
  if text_digest(stub) != sizes[1]
    return Ast.Optional.Absent
  end

  constants = decode_constants(after.slice(start + size.unwrap!, after.length - start - size.unwrap!))
  if !constants.ok?
    return Ast.Optional.Absent
  end

  if tree == NO_TREE
    tree = ""
  end

  return Ast.Optional.Present(Entry(tree: tree, stub: stub, constants: constants.unwrap!))
end

# The constants of the tail of an entry: nothing, or a line feed and a `const NAME TYPE` line for each.
def decode_constants(tail: String) -> Result[Map[String, String]]
  found: Map[String, String] = {}
  if tail == ""
    return ok(found)
  end

  lines = tail.split("\n")
  if lines[0] != ""
    return error("the entry has text after the stub")
  end

  prefix = "#{CONSTANT_WORD} "
  for line in lines.drop(1)
    if !line.starts_with?(prefix)
      return error("a constant line of the entry is wrong")
    end

    # The name ends at the first space; the type is the rest, which may hold spaces (the key of a file).
    rest = line.slice(prefix.length, line.length - prefix.length)
    space = rest.index_of(" ")
    if !space.ok? or space.unwrap! == 0 or space.unwrap! + 1 >= rest.length
      return error("a constant line of the entry is wrong")
    end

    name = rest.slice(0, space.unwrap!)
    if found.has_key?(name)
      return error("a constant appears twice in the entry")
    end

    found = found.put(name, unescaped(rest.slice(space.unwrap! + 1, rest.length - space.unwrap! - 1)))
  end

  return ok(found)
end

# A type text on one line: the key of a file may hold a line feed.
def escaped(text: String) -> String
  return text.replace("%", "%25").replace("\n", "%0A")
end

def unescaped(text: String) -> String
  return text.replace("%0A", "\n").replace("%25", "%")
end

# The pieces of the text to blank: the statements of each function body, from the first statement up to the `end` that
# closes the function (the last statement, a heredoc included, ends before it), and the value of each long constant. A
# declaration that the cut cannot be trusted for fails the stub.
def cuts_of(text: String, declarations: List[Ast.Decl]) -> Result[List[Cut]]
  cuts: List[Cut] = []
  floor = 0
  for wrapped in declarations
    found: List[Cut] = []
    case Declarations.unwrap(wrapped)
      Ast.Decl.Function(node) -> found = try body_cut(text, node)
      Ast.Decl.Constant(node) -> found = value_cut(node)
      _ -> next
    end

    for cut in found
      if cut.first < floor or cut.stop > text.length
        return error("the cuts overlap")
      end

      cuts = cuts.push(cut)
      floor = cut.stop
    end
  end

  return ok(cuts)
end

def body_cut(text: String, node: Ast.FunctionDecl) -> Result[List[Cut]]
  if node.body.size == 0
    return ok([])
  end

  first = Ast.stmt_span(node.body[0]).start.offset
  last = Ast.stmt_span(node.body[node.body.size - 1]).stop.offset
  # The span of a function ends after the line break that follows its `end`.
  stop = node.span.stop.offset
  while stop > last and stop <= text.length and " \t\r\n".contains?(text.slice(stop - 1, 1))
    stop -= 1
  end

  stop -= END_WORD.length
  if stop < last or stop + END_WORD.length > text.length or text.slice(stop, END_WORD.length) != END_WORD
    return error("the body of #{node.name} does not end where the stub needs it to")
  end

  return ok([Cut(first: first, stop: stop, wrap: false)])
end

def value_cut(node: Ast.ConstDecl) -> List[Cut]
  span = Ast.expr_span(node.value)
  if span.stop.offset - span.start.offset < ELIDE_FROM
    return []
  end

  return [Cut(first: span.start.offset, stop: span.stop.offset, wrap: true)]
end

# `piece` of the text as the stub has it, with the same length and line breaks. The statements of a body become a
# comment on each line but the first and the last, which are blanks: the last so the `end` after it keeps its place,
# the first so the look-ahead of the lexer for a line that starts with a dot (dot_follows?) stops there and does not
# walk the comment lines. A comment costs the lexer a step for the whole line, where blanks cost it a few steps each.
# The value of a constant becomes a parenthesized zero over the same characters: `(` first, `)` last, a `0` on the
# first line that has room for it, blanks around it on that line and the comment lines between. A value that does not
# have the room for that is left as it is.
def replacement(piece: String, wrap: Bool) -> String
  lines = piece.split("\n")
  widths = lines.map do |line: String| line.length - carriage(line).length end
  last = lines.size - 1
  zero = -1
  if wrap
    zero = zero_line(widths)
    if zero < 0
      return piece
    end
  end

  out: List[String] = []
  at = 0
  for line in lines
    out = out.push(cell(widths[at], at, last, wrap, zero) + carriage(line))
    at += 1
  end

  return out.join("\n")
end

# "\r" for a line that ends with one, which stays where it is.
def carriage(line: String) -> String
  if line.ends_with?("\r")
    return "\r"
  end

  return ""
end

# The line of a constant's value that holds the zero: the first with room for it beside the parenthesis the first and
# last line have, or -1.
def zero_line(widths: List[Int]) -> Int
  last = widths.size - 1
  if last == 0
    if widths[0] >= 3
      return 0
    end

    return -1
  end

  at = 0
  while at <= last
    room = 1
    if at == 0 or at == last
      room = 2
    end

    if widths[at] >= room
      return at
    end

    at += 1
  end

  return -1
end

# One line of a replacement, `width` characters long, the line `at` of lines 0 to `last`; `zero` is the line with the
# zero of a constant's value (-1 for the statements of a body).
def cell(width: Int, at: Int, last: Int, wrap: Bool, zero: Int) -> String
  if !wrap
    if at == 0 or at == last
      return blanks(width)
    end

    return commented(width)
  elsif last == 0
    return "(0" + blanks(width - 3) + ")"
  end

  opening = ""
  closing = ""
  if at == 0
    opening = "("
  end

  if at == last
    closing = ")"
  end

  if at == zero
    return opening + "0" + blanks(width - opening.length - 1 - closing.length) + closing
  elsif at == 0 or at == last
    return opening + blanks(width - opening.length - closing.length) + closing
  end

  return commented(width)
end

# A comment over `width` characters, or nothing for an empty line.
def commented(width: Int) -> String
  if width == 0
    return ""
  end

  return "#" + blanks(width - 1)
end

def blanks(count: Int) -> String
  out = ""
  left = count
  while left > BLANK_RUN
    out = out + BLANKS
    left -= BLANK_RUN
  end

  return out + BLANKS.slice(0, left)
end

# Whether the stub parses, and to the same declarations as the text: the same names, and each declaration over the same
# characters, so the spans of the headers are those of the text.
def same_declarations?(program: Ast.Program, stub: String) -> Bool
  case Lexer.lex(stub)
    Diag.Outcome.Failed(_) -> return false
    Diag.Outcome.Done(tokens) ->
      case Parser.parse(tokens, 0)
        Diag.Outcome.Failed(_) -> return false
        Diag.Outcome.Done(parsed) -> return same_list?(program.declarations, parsed.declarations)
      end
  end
end

def same_list?(whole: List[Ast.Decl], stub: List[Ast.Decl]) -> Bool
  if whole.size != stub.size
    return false
  end

  at = 0
  while at < whole.size
    here = Declarations.span_of(whole[at])
    there = Declarations.span_of(stub[at])
    if (
      Declarations.name_of(whole[at]) != Declarations.name_of(stub[at]) or
      here.start.offset != there.start.offset or
      here.stop.offset != there.stop.offset
    )
      return false
    end

    at += 1
  end

  return true
end

def hex(digest: List[Int]) -> String
  digits = "0123456789abcdef"
  return digest.map do |byte: Int| digits.at(byte / 16) + digits.at(byte % 16) end.join("")
end
