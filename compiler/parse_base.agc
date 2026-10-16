## The shared part of the Agentica parser: the context, the results, the failures, and the parts of the grammar that
## need no expressions (types and case patterns).
##
## A parser would keep its state in variables that it changes (the position, the nesting, the block flags). Agentica
## has no such variables, so every parse function takes the context (Env), a position and the next free node id, and
## returns the node with the new position and id. A failure is a Result error whose String is the packed diagnostic, so
## `try` stops at the first one.

import Ast from "ast"
import Diag from "diagnostic"
import Source from "source"
import Tokens from "token"
import Unicode from "unicode"

## What a parse function reads and never changes: the tokens, the context of the construct being parsed, and the
## nesting level. depth is the block depth (0 outside a do block body), allow_blocks tells whether `do` after a call
## starts a block, and brace_at and brace_form remember a `{` right after a block head, for the help of
## PARSE-UNEXPECTED-TOKEN.
export struct Env
  tokens: List[Tokens.Token]
  size: Int
  allow_blocks: Bool
  depth: Int
  brace_at: Int
  brace_form: String
  nesting: Int
end

## The result of parsing an expression: the node, the position of the next token, and the next free node id.
export struct ExprAt
  node: Ast.Expr
  pos: Int
  ids: Int
end

## A list of expressions with the next position and the next free node id.
export struct ExprsAt
  nodes: List[Ast.Expr]
  pos: Int
  ids: Int
end

## A statement with the next position and the next free node id.
export struct StmtAt
  node: Ast.Stmt
  pos: Int
  ids: Int
end

## A list of statements with the next position and the next free node id.
export struct StmtsAt
  nodes: List[Ast.Stmt]
  pos: Int
  ids: Int
end

## A type with the next position and the next free node id.
export struct TypeAt
  node: Ast.TypeRef
  pos: Int
  ids: Int
end

## A pattern with the next position and the next free node id.
export struct PatternAt
  node: Ast.Pattern
  pos: Int
  ids: Int
end

# The payload slots of a variant pattern, with the next position and the next free node id.
struct SlotsAt
  slots: List[Ast.Slot]
  pos: Int
  ids: Int
end

# One slot with the next position and the next free node id.
struct SlotAt
  slot: Ast.Slot
  pos: Int
  ids: Int
end

# Where a pattern item ends in the look-ahead: the index after a leaf or after the `(` of a variant that opens a list
# of slots, or -1 when the tokens are no pattern.
struct Scanned
  next: Int
  opens: Bool
end

## The deepest nesting the parser accepts (PARSE-TOO-DEEP beyond it). Each statement, expression, prefix operator and
## type level counts one, and so does each operator or suffix (link) of a chain such as a + b + c or a.b.c: everything
## parsed after the k-th link of a chain (its right operand, arguments, index or block) starts from the depth of the
## chain plus k. The counter bounds the calls of the parser: a level uses up to about 8 VM calls (equality and
## comparison add no level but cost frames; measured: `M.f(1 == 1 < ` nested overflows near 1,250 levels, 1.25 times
## the limit), so the limit stays below the VM limit of 10,000 (RUNTIME-STACK-OVERFLOW). It does not bound the depth of
## the tree: the right operand of the first link of a chain hangs below the whole chain, so nested chains build deeper
## trees, and a pass that recurses on the tree needs its own stack or limit. The limit counts nesting
## the same way in every stage.
export def nesting_limit() -> Int
  return 1000
end

## The context for the start of a file.
export def make_env(tokens: List[Tokens.Token]) -> Env
  return Env(tokens: tokens, size: tokens.size, allow_blocks: true, depth: 0, brace_at: -1, brace_form: "", nesting: 0)
end

## The same context, with `do` blocks allowed or not. Headers of case, while and for do not allow them.
export def with_blocks(e: Env, allow: Bool) -> Env
  return Env(
    tokens: e.tokens,
    size: e.size,
    allow_blocks: allow,
    depth: e.depth,
    brace_at: e.brace_at,
    brace_form: e.brace_form,
    nesting: e.nesting,
  )
end

## The same context for the body of a block or a case arm.
export def with_depth(e: Env, depth: Int) -> Env
  return Env(
    tokens: e.tokens,
    size: e.size,
    allow_blocks: e.allow_blocks,
    depth: depth,
    brace_at: e.brace_at,
    brace_form: e.brace_form,
    nesting: e.nesting,
  )
end

## The context for the body of a do block, remembering a `{` that follows the block head.
export def with_block_body(e: Env, brace_at: Int, brace_form: String) -> Env
  return Env(
    tokens: e.tokens,
    size: e.size,
    allow_blocks: true,
    depth: 1,
    brace_at: brace_at,
    brace_form: brace_form,
    nesting: e.nesting,
  )
end

## The kind of the token at an index. An index past the end reads the last token (EOF).
export def kind_at(e: Env, index: Int) -> String
  if index < e.size
    return e.tokens[index].kind
  end
  return e.tokens[e.size - 1].kind
end

## True for the name of a module constant: capitals, digits and `_`, starting with a capital, at least two characters
## (UPPER_SNAKE_CASE). The lexer makes every such name a type-name token; this tells it from a CamelCase type.
export def constant_name?(text: String) -> Bool
  codes = text.split("").map do |character| String.code(character) end
  if codes.size < 2 or codes[0] < 65 or codes[0] > 90
    return false
  end
  index = 1
  while index < codes.size
    code = codes[index]
    if !((code >= 65 and code <= 90) or (code >= 48 and code <= 57) or code == 95)
      return false
    end
    index += 1
  end
  return true
end

## The span from the start of the token at start to the end of the last token before pos, that is, the last consumed
## token.
export def span_from(e: Env, start: Int, pos: Int) -> Source.Span
  return Source.Span(start: e.tokens[start].span.start, stop: e.tokens[pos - 1].span.stop)
end

## How a token is named in "found ..." messages. The lexeme is shown in the form of `written_text` (unicode.agc).
export def describe(token: Tokens.Token) -> String
  if token.lexeme == ""
    return token.kind
  end
  if token.kind == "NL"
    return "a newline"
  end
  if token.kind == "interp-middle" or token.kind == "interp-end"
    return "\"}\""
  end
  return Unicode.written_text(token.lexeme)
end

## Reads back the failure that pack wrote.
export def unpack(text: String) -> Diag.Diagnostic
  parts = text.split("\n")
  consumed = 0
  index = 0
  while index < 9
    consumed += parts[index].length + 1
    index += 1
  end
  body = text.slice(consumed, text.length - consumed)
  size = parts[8].to_i!
  help = Diag.Help.NoHelp
  if parts[7] == "1"
    help = Diag.Help.Hint(body.slice(size, body.length - size))
  end
  start = Source.Position(offset: parts[1].to_i!, line: parts[2].to_i!, column: parts[3].to_i!)
  stop = Source.Position(offset: parts[4].to_i!, line: parts[5].to_i!, column: parts[6].to_i!)
  return Diag.fail(parts[0], body.slice(0, size), Source.Span(start: start, stop: stop), help)
end

## A help text.
export def hint(text: String) -> Diag.Help
  return Diag.Help.Hint(text)
end

## The failure for a span that is not the span of one token.
export def bail_span(code: String, message: String, span: Source.Span, help: Diag.Help) -> String
  return pack(code, message, span, help)
end

## The failure for the token at at. A doc comment token always gives PARSE-DETACHED-DOC, except for
## PARSE-MISSING-BLANK-LINE.
export def bail(e: Env, at: Int, code: String, message: String, help: Diag.Help) -> String
  token = e.tokens[at]
  if token.kind == "DOC" and code != "PARSE-MISSING-BLANK-LINE"
    return detached_doc(token)
  end
  return pack(code, message, token.span, help)
end

## The PARSE-DETACHED-DOC failure for the doc token at at.
export def bail_detached(e: Env, at: Int) -> String
  return detached_doc(e.tokens[at])
end

## A PARSE-UNEXPECTED-TOKEN failure without help.
export def unexpected(e: Env, at: Int, message: String) -> String
  return bail(e, at, "PARSE-UNEXPECTED-TOKEN", message, Diag.Help.NoHelp)
end

## A PARSE-UNEXPECTED-TOKEN failure with a help text.
export def unexpected_help(e: Env, at: Int, message: String, help: String) -> String
  return bail(e, at, "PARSE-UNEXPECTED-TOKEN", message, hint(help))
end

## "expected X, found Y" for the token at at.
export def found(e: Env, at: Int, expected: String) -> String
  return unexpected(e, at, "expected #{expected}, found #{describe(e.tokens[at])}")
end

## The context `levels` deeper than e; PARSE-TOO-DEEP when that passes nesting_limit. enter adds one level, deepen adds
## the k links of a chain so far.
export def deepen(e: Env, pos: Int, levels: Int) -> Result[Env]
  if e.nesting + levels > nesting_limit()
    return error(too_deep(e, pos))
  end
  return ok(
    Env(
      tokens: e.tokens,
      size: e.size,
      allow_blocks: e.allow_blocks,
      depth: e.depth,
      brace_at: e.brace_at,
      brace_form: e.brace_form,
      nesting: e.nesting + levels,
    ),
  )
end

## Counts one more level of nesting; PARSE-TOO-DEEP when that passes nesting_limit.
export def enter(e: Env, pos: Int) -> Result[Env]
  return deepen(e, pos, 1)
end

## A failure for a state the grammar functions cannot reach, so that no code path needs a bare string error:
## PARSE-UNEXPECTED-TOKEN at the token at pos.
export def impossible(e: Env, pos: Int) -> String
  return unexpected(e, pos, "the parser cannot continue at #{describe(e.tokens[pos])}")
end

## True for a name token without a ? or ! suffix: the names of fields, parameters and bindings.
export def plain_name?(token: Tokens.Token) -> Bool
  return token.kind == "name" and !decorated?(token.lexeme)
end

## The position after the token at pos when it has the kind. A name that ends in ? or ! is refused unless suffix is
## true, which only function and method names allow.
export def expect(e: Env, pos: Int, kind: String, description: String, suffix: Bool) -> Result[Int]
  token = e.tokens[pos]
  if token.kind == kind and !(kind == "name" and !suffix and decorated?(token.lexeme))
    return ok(pos + 1)
  end
  return error(found(e, pos, description))
end

## The position of the first token at or after pos that is not NL.
export def skip_newlines(e: Env, pos: Int) -> Int
  cursor = pos
  while e.tokens[cursor].kind == "NL"
    cursor += 1
  end
  return cursor
end

## The text of a token whose value is a string.
export def token_text(token: Tokens.Token) -> String
  case token.value
    Tokens.Value.Text(text) -> return text
    _ -> return ""
  end
end

## Whether a `string` token is a heredoc (25.10). The lexer gives a heredoc the lexeme of its opener, `<<~NAME`, and
## a string literal the lexeme of its quotes, so the parser tells them apart with no field on the token.
export def heredoc?(token: Tokens.Token) -> Bool
  return token.lexeme.starts_with?("<<~")
end

## The literal value of an integer, float or string token.
export def literal_value(token: Tokens.Token) -> Ast.LitValue
  case token.value
    Tokens.Value.Whole(number) -> return Ast.LitValue.Whole(number)
    Tokens.Value.Huge(digits) -> return Ast.LitValue.Huge(digits)
    Tokens.Value.Real(number) -> return Ast.LitValue.Real(number)
    Tokens.Value.Text(text) -> return Ast.LitValue.Text(text)
    _ -> return Ast.LitValue.Nothing
  end
end

## Parses a type: Name, Mod.Name, or Name[Type, ...].
export def parse_type(e: Env, pos: Int, ids: Int) -> Result[TypeAt]
  inner = try enter(e, pos)
  name = e.tokens[pos].lexeme
  cursor = try expect(e, pos, "type-name", "a type name", false)
  if is_kind(e, cursor, "dot")
    stop = try expect(e, cursor + 1, "type-name", "an imported type name", false)
    name = "#{name}.#{e.tokens[cursor + 1].lexeme}"
    cursor = stop
  end
  args: List[Ast.TypeRef] = []
  next_id = ids
  if is_kind(e, cursor, "left-bracket")
    first = try parse_type(inner, cursor + 1, next_id)
    args = args.push(first.node)
    cursor = first.pos
    next_id = first.ids
    while is_kind(e, cursor, "comma")
      more = try parse_type(inner, cursor + 1, next_id)
      args = args.push(more.node)
      cursor = more.pos
      next_id = more.ids
    end
    cursor = try expect(e, cursor, "right-bracket", "\"]\"", false)
  end
  node = Ast.TypeRef(id: next_id, name: name, args: args, span: span_from(e, pos, cursor))
  return ok(TypeAt(node: node, pos: cursor, ids: next_id + 1))
end

## Parses the pattern of a case arm.
export def parse_pattern(e: Env, pos: Int, ids: Int) -> Result[PatternAt]
  token = e.tokens[pos]
  kind = token.kind
  if kind == "name"
    return parse_name_pattern(e, pos, ids)
  end
  if kind == "string" and heredoc?(token)
    return error(
      unexpected_help(e, pos, "a heredoc is not a pattern", "write the pattern as a \"...\" string literal"),
    )
  end
  if kind == "integer" or kind == "float" or kind == "string"
    return literal_pattern(e, ids, literal_value(token), pos, pos + 1)
  end
  if kind == "true" or kind == "false"
    return literal_pattern(e, ids, Ast.LitValue.Flag(kind == "true"), pos, pos + 1)
  end
  if kind == "nil"
    return literal_pattern(e, ids, Ast.LitValue.Nothing, pos, pos + 1)
  end
  if kind == "minus"
    number = e.tokens[pos + 1]
    if number.kind != "integer" and number.kind != "float"
      return error(unexpected(e, pos + 1, "expected a number after - in a pattern"))
    end
    return literal_pattern(e, ids, negated(literal_value(number)), pos, pos + 2)
  end
  if kind == "type-name"
    return parse_variant_pattern(e, pos, ids)
  end
  return error(unexpected(e, pos, "expected a pattern"))
end

## Whether the tokens at pos start a case arm, that is, a pattern, an optional `if` guard and ->. A case body ends
## there, because arms have no closing token. A guard is looked for up to the end of its line.
export def case_arm_start?(e: Env, pos: Int) -> Bool
  stop = pattern_end(e, pos)
  if stop < 0
    return false
  end
  if kind_at(e, stop) == "if"
    return guard_arrow(e, stop + 1) >= 0
  end
  return kind_at(e, stop) == "arrow"
end

def is_kind(e: Env, pos: Int, kind: String) -> Bool
  return e.tokens[pos].kind == kind
end

# A Result error is a String, so the diagnostic travels packed: the code, the six numbers of the span, a help flag, the
# length of the message, then the message followed by the help.
def pack(code: String, message: String, span: Source.Span, help: Diag.Help) -> String
  numbers = [span.start.offset, span.start.line, span.start.column, span.stop.offset, span.stop.line, span.stop.column]
  fields = numbers.map do |number| number.to_s end
  rest = message
  flag = "0"
  case help
    Diag.Help.Hint(text) ->
      rest = message + text
      flag = "1"
    Diag.Help.NoHelp -> flag = "0"
  end
  return "#{code}\n#{fields.join("\n")}\n#{flag}\n#{message.length}\n#{rest}"
end

def detached_doc(token: Tokens.Token) -> String
  return pack(
    "PARSE-DETACHED-DOC",
    "a doc comment must be followed by a declaration, field or variant on the next line",
    token.span,
    hint(
      (
        "put the doc block directly above the declaration, field or variant it documents; " +
        "use # for a note that documents nothing"
      ),
    ),
  )
end

# The PARSE-TOO-DEEP failure at the token at pos.
def too_deep(e: Env, pos: Int) -> String
  return bail(
    e,
    pos,
    "PARSE-TOO-DEEP",
    "nesting is deeper than #{nesting_limit()} levels",
    hint("split the code into smaller functions or simpler expressions"),
  )
end

def decorated?(lexeme: String) -> Bool
  return lexeme.ends_with?("?") or lexeme.ends_with?("!")
end

# One payload slot: a name binds the value, `_` drops it, and a literal, a variant, ok(...) or error(...) is a nested
# pattern. A nested variant counts one level of nesting, which bounds the calls of the parser on a deep pattern.
def parse_slot(e: Env, pos: Int, ids: Int) -> Result[SlotAt]
  token = e.tokens[pos]
  kind = token.kind
  if kind == "name"
    lexeme = token.lexeme
    if (lexeme == "ok" or lexeme == "error") and is_kind(e, pos + 1, "left-paren")
      return nested_slot(e, pos, ids)
    end
    advanced = try expect(e, pos, "name", "a pattern binding or _", false)
    slot = Ast.Slot.Bind(lexeme)
    if lexeme == "_"
      slot = Ast.Slot.Skip
    end
    return ok(SlotAt(slot: slot, pos: advanced, ids: ids))
  end
  if kind == "integer" or kind == "float" or kind == "string" or kind == "true" or kind == "false" or kind == "nil"
    return nested_slot(e, pos, ids)
  end
  if kind == "type-name"
    return nested_slot(e, pos, ids)
  end
  if kind == "minus" and (kind_at(e, pos + 1) == "integer" or kind_at(e, pos + 1) == "float")
    return nested_slot(e, pos, ids)
  end
  return error(found(e, pos, "a pattern binding or _"))
end

def nested_slot(e: Env, pos: Int, ids: Int) -> Result[SlotAt]
  inner = try enter(e, pos)
  parsed = try parse_pattern(inner, pos, ids)
  return ok(SlotAt(slot: Ast.Slot.Nested(parsed.node), pos: parsed.pos, ids: parsed.ids))
end

# The slots of the parentheses that open at pos: one or more, separated by commas.
def parse_slots(e: Env, pos: Int, ids: Int, empty_help: String) -> Result[SlotsAt]
  if is_kind(e, pos + 1, "right-paren")
    return error(unexpected_help(e, pos + 1, "a pattern with parentheses needs a binding or _", empty_help))
  end
  slots: List[Ast.Slot] = []
  cursor = pos + 1
  next_id = ids
  looping = true
  while looping
    parsed = try parse_slot(e, cursor, next_id)
    slots = slots.push(parsed.slot)
    cursor = parsed.pos
    next_id = parsed.ids
    if is_kind(e, cursor, "comma")
      cursor += 1
    else
      looping = false
    end
  end
  cursor = try expect(e, cursor, "right-paren", ")", false)
  return ok(SlotsAt(slots: slots, pos: cursor, ids: next_id))
end

def pattern_node(
  e: Env,
  id: Int,
  enum_name: String,
  variant_name: String,
  slots: List[Ast.Slot],
  start: Int,
  cursor: Int,
) -> Ast.Pattern
  return Ast.Pattern.Variant(
    Ast.VariantPattern(
      id: id,
      enum_name: enum_name,
      variant_name: variant_name,
      slots: slots,
      span: span_from(e, start, cursor),
    ),
  )
end

# A negative literal pattern is a single literal with the negated value (an Int too big for Int keeps its digits).
def literal_pattern(e: Env, ids: Int, value: Ast.LitValue, start: Int, cursor: Int) -> Result[PatternAt]
  node = Ast.Pattern.Literal(Ast.LiteralPattern(id: ids, value: value, span: span_from(e, start, cursor)))
  return ok(PatternAt(node: node, pos: cursor, ids: ids + 1))
end

def negated(value: Ast.LitValue) -> Ast.LitValue
  case value
    Ast.LitValue.Whole(number) -> return Ast.LitValue.Whole(0 - number)
    Ast.LitValue.Huge(digits) -> return Ast.LitValue.Huge("-#{digits}")
    Ast.LitValue.Real(number) -> return Ast.LitValue.Real(-number)
    _ -> return value
  end
end

def parse_name_pattern(e: Env, pos: Int, ids: Int) -> Result[PatternAt]
  token = e.tokens[pos]
  lexeme = token.lexeme
  if lexeme == "_"
    node = Ast.Pattern.Wildcard(Ast.WildcardPattern(id: ids, span: token.span))
    return ok(PatternAt(node: node, pos: pos + 1, ids: ids + 1))
  end
  if (lexeme == "ok" or lexeme == "error") and is_kind(e, pos + 1, "left-paren")
    parsed = try parse_slots(e, pos + 1, ids, "write #{lexeme}(_) to match without binding the value")
    variant = "Err"
    if lexeme == "ok"
      variant = "Ok"
    end
    # The node follows the ids of its nested patterns (post-order); with none, its id is `ids`, as it always was.
    node = pattern_node(e, parsed.ids, "Result", variant, parsed.slots, pos, parsed.pos)
    return ok(PatternAt(node: node, pos: parsed.pos, ids: parsed.ids + 1))
  end
  if lexeme == "when"
    return error(
      unexpected_help(
        e,
        pos,
        "expected a pattern, found \"when\"",
        "case arms have no when: write the pattern and ->, as in 1 -> puts(\"one\")",
      ),
    )
  end
  return error(unexpected(e, pos, "expected a pattern"))
end

def variant_help(enum_name: String, variant_name: String) -> String
  if enum_name == "Result" or (enum_name == "Await" and variant_name == "Done")
    return "write #{enum_name}.#{variant_name}(_) to match without binding the value"
  end
  return "a variant without payload has no parentheses: #{enum_name}.#{variant_name}"
end

def parse_variant_pattern(e: Env, pos: Int, ids: Int) -> Result[PatternAt]
  if !is_kind(e, pos + 1, "dot") and constant_name?(e.tokens[pos].lexeme)
    return error(
      unexpected_help(
        e,
        pos + 1,
        "expected a dot between an enum and variant, found #{describe(e.tokens[pos + 1])}",
        "a constant is not a pattern; compare with if",
      ),
    )
  end
  cursor = try expect(e, pos + 1, "dot", "a dot between an enum and variant", false)
  after = try expect(e, cursor, "type-name", "a variant name", false)
  enum_name = e.tokens[pos].lexeme
  variant_name = e.tokens[cursor].lexeme
  cursor = after
  if is_kind(e, cursor, "dot")
    last = try expect(e, cursor + 1, "type-name", "a variant name", false)
    enum_name = "#{enum_name}.#{variant_name}"
    variant_name = e.tokens[cursor + 1].lexeme
    cursor = last
  end
  slots: List[Ast.Slot] = []
  next_id = ids
  if is_kind(e, cursor, "left-paren")
    parsed = try parse_slots(e, cursor, ids, variant_help(enum_name, variant_name))
    slots = parsed.slots
    cursor = parsed.pos
    next_id = parsed.ids
  end
  node = pattern_node(e, next_id, enum_name, variant_name, slots, pos, cursor)
  return ok(PatternAt(node: node, pos: cursor, ids: next_id + 1))
end

# The case_arm_start? helpers look ahead without consuming; they return the index after the pattern, or -1.
# The index after the segments of a qualified variant (`Enum.Variant`, or one more segment for a module alias), or -1.
def variant_head_end(e: Env, index: Int) -> Int
  at = index + 1
  segments = 1
  while kind_at(e, at) == "dot"
    if segments >= 3 or kind_at(e, at + 1) != "type-name"
      return -1
    end
    at += 2
    segments += 1
  end
  if segments < 2
    return -1
  end
  return at
end

# One item of a pattern at `at`: a leaf ends at `next`; a variant with parentheses `opens` a list of slots, and `next`
# is the index after its `(`. A name is an item only inside such a list, where it binds (a `_` is one anywhere).
def scan_item(e: Env, at: Int, inside: Bool) -> Scanned
  token = e.tokens[at]
  kind = token.kind
  if kind == "name"
    if (token.lexeme == "ok" or token.lexeme == "error") and kind_at(e, at + 1) == "left-paren"
      return Scanned(next: at + 2, opens: true)
    end
    if token.lexeme == "_" or inside
      return Scanned(next: at + 1, opens: false)
    end
  elsif kind == "integer" or kind == "float" or kind == "string" or kind == "true" or kind == "false" or kind == "nil"
    return Scanned(next: at + 1, opens: false)
  elsif kind == "minus"
    following = kind_at(e, at + 1)
    if following == "integer" or following == "float"
      return Scanned(next: at + 2, opens: false)
    end
  elsif kind == "type-name"
    head = variant_head_end(e, at)
    if head >= 0 and kind_at(e, head) == "left-paren"
      return Scanned(next: head + 1, opens: true)
    elsif head >= 0
      return Scanned(next: head, opens: false)
    end
  end
  return Scanned(next: -1, opens: false)
end

# The index after the pattern that starts at `start`, or -1. One pass over the tokens with a count of open
# parentheses, no recursion: a long run of nested patterns costs no stack here, before the parser has counted its
# depth.
def pattern_end(e: Env, start: Int) -> Int
  cursor = start
  open = 0
  while true
    item = scan_item(e, cursor, open > 0)
    if item.next < 0
      return -1
    end
    cursor = item.next
    if item.opens
      open += 1
    else
      closing = true
      while closing
        if open == 0
          return cursor
        end
        following = kind_at(e, cursor)
        if following == "comma"
          cursor += 1
          closing = false
        elsif following == "right-paren"
          cursor += 1
          open -= 1
        else
          return -1
        end
      end
    end
  end
  return -1
end

# The index of the `->` that ends a guard on its line, or -1. A guard is an expression, so no `->` is inside it.
def guard_arrow(e: Env, from: Int) -> Int
  cursor = from
  while true
    kind = kind_at(e, cursor)
    if kind == "arrow"
      return cursor
    elsif kind == "NL" or kind == "EOF"
      return -1
    end
    cursor += 1
  end
  return -1
end
