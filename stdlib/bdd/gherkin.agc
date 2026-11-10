## Reads Gherkin feature files for `agentica test`.
##
## It supports `Feature`, `Background`, `Scenario`, `Scenario Outline` with `Examples`, tags, Doc Strings and Data
## Tables, in English only.

import Report from "std/test/report"

## A problem in a feature file: a code, a message and its place.
export struct Diagnostic
  code: String
  message: String
  span: Report.Span
end

## The result of a read that can fail: `Done` with a value, or `Failed` with a `Diagnostic`.
export enum Outcome[T]
  Done(T)
  Failed(Diagnostic)
end

## What follows a step: nothing, a Doc String or a Data Table.
export enum Argument
  NoArgument
  DocString(String)
  DataTable(List[List[String]])
end

## One step of a scenario: its kind (`Given`, `When` or `Then`), the text after the keyword, its argument and its
## place.
export struct Step
  kind: String
  text: String
  argument: Argument
  span: Report.Span
end

## One scenario, with the `Background` steps first, the tags of the feature, of the scenario and of its `Examples`
## block, and the example row it came from.
export struct Scenario
  name: String
  steps: List[Step]
  tags: List[String]
  span: Report.Span
  example: Report.Example
end

## A parsed feature file. A `Scenario Outline` is already expanded into one scenario for each `Examples` row.
export struct Feature
  name: String
  scenarios: List[Scenario]
  tags: List[String]
  span: Report.Span
end

struct Source
  file: String
  raws: List[String]
  texts: List[String]
end

struct ExampleRow
  span: Report.Span
  headers: List[String]
  cells: List[String]
  bindings: Map[String, String]
  tags: List[String]
end

struct Draft
  name: String
  outline: Bool
  steps: List[Step]
  examples: List[ExampleRow]
  tags: List[String]
  span: Report.Span
end

struct TableRow
  span: Report.Span
  cells: List[String]
end

struct Table
  rows: List[TableRow]
  next: Int
end

struct Doc
  text: String
  next: Int
end

## Parses the text of the feature file `file`. Returns the `Feature`, or a `Diagnostic` for the first problem.
export def parse(file: String, text: String) -> Outcome[Feature]
  src = read_lines(file, text)
  count = src.raws.size
  cursor = 0
  title = ""
  has_title = false
  title_span = location(src, 0)
  feature_tags: List[String] = []
  pending: List[String] = []
  background: List[Step] = []
  has_background = false
  drafts: List[Draft] = []
  current = Draft(name: "", outline: false, steps: [], examples: [], tags: [], span: title_span)
  has_current = false
  mode = ""
  previous = ""
  while cursor < count
    line = src.texts[cursor]
    where = location(src, cursor)
    heading = heading_keyword(line)
    action = step_keyword(line)
    if line == "" or line.start_with?("#")
      if line.start_with?("# language:") and line != "# language: en"
        return fail("PARSE-GHERKIN-UNSUPPORTED", "only English Gherkin is supported", where)
      end
      cursor += 1
    elsif line.start_with?("@")
      return fail("PARSE-GHERKIN-TAGS", "invalid tags", where) if not tags?(line)
      pending = pending.concat(split_tags(line))
      cursor += 1
    elsif heading != ""
      name = drop_blanks(rest_of(line, heading.length + 1))
      if name == "" and heading != "Examples" and heading != "Background"
        return fail("PARSE-GHERKIN-HEADER", "a section needs a name", where)
      end
      if heading == "Feature"
        return fail("PARSE-GHERKIN-HEADER", "one Feature is allowed per file", where) if has_title
        title = name
        has_title = true
        title_span = where
        feature_tags = pending
        pending = []
        cursor += 1
      elsif not has_title
        return fail("PARSE-GHERKIN-HEADER", "Feature must come first", where)
      elsif heading == "Background"
        if has_background or has_current or pending.size > 0
          return fail("PARSE-GHERKIN-HEADER", "Background must occur once before scenarios, without tags", where)
        end
        has_background = true
        mode = "background"
        previous = ""
        cursor += 1
      elsif heading == "Examples"
        if not (has_current and current.outline)
          return fail("PARSE-GHERKIN-EXAMPLES", "Examples requires a Scenario Outline", where)
        end
        example_tags = pending
        pending = []
        cursor += 1
        while cursor < count and (src.texts[cursor] == "" or src.texts[cursor].start_with?("#"))
          cursor += 1
        end
        block = Table(rows: [], next: cursor)
        case read_table(src, cursor)
          Outcome.Done(found) -> block = found
          Outcome.Failed(problem) -> return Outcome.Failed(problem)
        end
        cursor = block.next
        if block.rows.size < 2
          return fail("PARSE-GHERKIN-EXAMPLES", "Examples needs a header and at least one row", where)
        end
        headers = block.rows[0].cells
        if not unique_names?(headers)
          return fail("PARSE-GHERKIN-EXAMPLES", "Examples headers must be nonempty and unique", where)
        end
        rows = current.examples
        for row in block.rows.drop(1)
          bindings = bind(headers, row.cells)
          rows = rows.push(
            ExampleRow(span: row.span, headers: headers, cells: row.cells, bindings: bindings, tags: example_tags),
          )
        end

        current = with_examples(current, rows)
        mode = "examples"
      else
        if has_current
          drafts = drafts.push(current)
        end
        current = Draft(
          name: name,
          outline: heading == "Scenario Outline",
          steps: [],
          examples: [],
          tags: pending,
          span: where,
        )

        has_current = true
        pending = []
        mode = "scenario"
        previous = ""
        cursor += 1
      end
    elsif action != ""
      if mode != "background" and mode != "scenario"
        return fail("PARSE-GHERKIN-STEP", "a step requires Background or Scenario", where)
      end
      return fail("PARSE-GHERKIN-TAGS", "tags must precede a section", where) if pending.size > 0
      kind = action
      if action == "And" or action == "But"
        kind = previous
      end
      return fail("PARSE-GHERKIN-STEP", "And or But needs a preceding step", where) if kind == ""
      previous = kind
      step = Step(
        kind: kind,
        text: drop_blanks(rest_of(line, action.length)),
        argument: Argument.NoArgument,
        span: at_keyword(where, src.raws[cursor]),
      )

      if mode == "background"
        background = background.push(step)
      else
        current = with_steps(current, current.steps.push(step))
      end
      cursor += 1
    elsif line.start_with?("\"\"\"") or line.start_with?("|")
      argument = Argument.NoArgument
      if line.start_with?("|")
        block = Table(rows: [], next: cursor)
        case read_table(src, cursor)
          Outcome.Done(found) -> block = found
          Outcome.Failed(problem) -> return Outcome.Failed(problem)
        end
        cursor = block.next
        argument = Argument.DataTable(block.rows.map do |row| row.cells end)
      else
        doc = Doc(text: "", next: cursor)
        case read_doc(src, cursor)
          Outcome.Done(found) -> doc = found
          Outcome.Failed(problem) -> return Outcome.Failed(problem)
        end
        cursor = doc.next
        argument = Argument.DocString(doc.text)
      end
      here = location(src, cursor)
      if (mode != "background" and mode != "scenario") or pending.size > 0
        return fail("PARSE-GHERKIN-ARGUMENT", "step argument is outside a step", here)
      end
      active = active_steps(mode, background, current, has_current)
      if active.size == 0 or has_argument?(active[active.size - 1])
        return fail("PARSE-GHERKIN-ARGUMENT", "a step accepts one Doc String or Data Table", here)
      end
      last = active[active.size - 1]
      active = active.set(active.size - 1, Step(kind: last.kind, text: last.text, argument: argument, span: last.span))
      if mode == "background"
        background = active
      else
        current = with_steps(current, active)
      end
    elsif unsupported?(line)
      return fail("PARSE-GHERKIN-UNSUPPORTED", "unsupported or invalid Gherkin syntax", where)
    else
      if (
        not has_title or
        active_steps(mode, background, current, has_current).size > 0 or
        pending.size > 0 or
        mode == "examples"
      )
        return fail("PARSE-GHERKIN-STEP", "unexpected text after steps", where)
      end
      cursor += 1
    end
  end
  return fail("PARSE-GHERKIN-HEADER", "missing Feature", location(src, 0)) if not has_title
  return fail("PARSE-GHERKIN-TAGS", "tags without a section", location(src, 0)) if pending.size > 0
  return fail("PARSE-GHERKIN-EMPTY", "Feature needs at least one scenario", title_span) if not has_current
  return fail("PARSE-GHERKIN-EMPTY", "Background needs steps", title_span) if has_background and background.size == 0
  drafts = drafts.push(current)
  scenarios: List[Scenario] = []
  for draft in drafts
    return fail("PARSE-GHERKIN-EMPTY", "Scenario needs steps", draft.span) if draft.steps.size == 0
    if draft.outline and draft.examples.size == 0
      return fail("PARSE-GHERKIN-EXAMPLES", "Scenario Outline needs Examples", draft.span)
    end
    steps = background.concat(draft.steps)
    tags = feature_tags.concat(draft.tags)
    if draft.outline
      for row in draft.examples
        scenarios = scenarios.push(expand_row(draft, steps, tags, row))
      end
    else
      scenarios = scenarios.push(
        Scenario(name: draft.name, steps: steps, tags: tags, span: draft.span, example: Report.Example.NoExample),
      )
    end
  end
  return Outcome.Done(Feature(name: title, scenarios: scenarios, tags: feature_tags, span: title_span))
end

def problem(code: String, message: String, span: Report.Span) -> Diagnostic
  return Diagnostic(code: code, message: message, span: span)
end

def fail(code: String, message: String, span: Report.Span) -> Outcome[Feature]
  return Outcome.Failed(problem(code, message, span))
end

def read_lines(file: String, text: String) -> Source
  raws = text.split("\n").map do |part|
    return part.slice(0, part.length - 1) if part.end_with?("\r")
    part
  end

  return Source(file: file, raws: raws, texts: raws.map do |raw| raw.strip end)
end

# A location covers its whole raw line; past the end it is the last line.
def location(src: Source, index: Int) -> Report.Span
  at = index
  if at >= src.raws.size
    at = src.raws.size - 1
  end
  return Report.Span(file: src.file, line: at + 1, column: 1, end_column: src.raws[at].length + 1)
end

# A step's place starts at its keyword, so a report points past the indentation. The skipped blanks are the ones
# `strip` removes, since the line was classified through it.
def at_keyword(where: Report.Span, raw: String) -> Report.Span
  return Report.Span(file: where.file, line: where.line, column: strip_prefix(raw) + 1, end_column: where.end_column)
end

def strip_prefix(text: String) -> Int
  count = 0
  for c in text.split("")
    return count if not " \t\n\r".include?(c) and c != String.from_code(12)

    count += 1
  end
  return count
end

def rest_of(text: String, start: Int) -> String = text.slice(start, text.length - start)

def blank_prefix(text: String) -> Int
  count = 0
  for c in text.split("")
    return count if c != " " and c != "\t"
    count += 1
  end
  return count
end

def drop_blanks(text: String) -> String = rest_of(text, blank_prefix(text))

def heading_keyword(line: String) -> String
  colon = line.index_of(":")
  return "" if colon.none?
  word = line.slice(0, colon.unwrap!)
  if (
    word == "Feature" or
    word == "Background" or
    word == "Scenario Outline" or
    word == "Scenario" or
    word == "Example" or
    word == "Examples"
  )
    return word
  end
  return ""
end

def step_keyword(line: String) -> String
  word = line.replace("\t", " ").split(" ")[0]
  if (
    word.length < line.length and
    (word == "Given" or word == "When" or word == "Then" or word == "And" or word == "But")
  )
    return word
  end
  return ""
end

def unsupported?(line: String) -> Bool
  for prefix in ["Rule:", "Scenario Template:", "Scenarios:", "* ", "```", "Given:", "When:", "Then:", "And:", "But:"]
    return true if line.start_with?(prefix)
  end
  return false
end

def tags?(line: String) -> Bool
  for tag in line.replace("\t", " ").split(" ")
    return false if tag != "" and (tag.length < 2 or not tag.start_with?("@"))
  end
  return true
end

def split_tags(line: String) -> List[String]
  spaced = line.replace("\t", " ").replace("\r", " ").replace(String.from_code(12), " ")
  return spaced.split(" ").filter do |tag| tag != "" end
end

def doc_delimiter?(line: String) -> Bool
  allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./+-"
  for c in rest_of(line, 3).split("")
    return false if not allowed.include?(c)
  end
  return true
end

def unique_names?(names: List[String]) -> Bool
  seen: Map[String, Bool] = {}
  for name in names
    return false if name == "" or seen.has_key?(name)
    seen = seen.put(name, true)
  end
  return true
end

def bind(headers: List[String], cells: List[String]) -> Map[String, String]
  bindings: Map[String, String] = {}
  for i in 0...headers.size
    bindings = bindings.put(headers[i], cells[i])
  end
  return bindings
end

def with_steps(draft: Draft, steps: List[Step]) -> Draft
  return Draft(
    name: draft.name,
    outline: draft.outline,
    steps: steps,
    examples: draft.examples,
    tags: draft.tags,
    span: draft.span,
  )
end

def with_examples(draft: Draft, rows: List[ExampleRow]) -> Draft
  return Draft(
    name: draft.name,
    outline: draft.outline,
    steps: draft.steps,
    examples: rows,
    tags: draft.tags,
    span: draft.span,
  )
end

def active_steps(mode: String, background: List[Step], current: Draft, has_current: Bool) -> List[Step]
  return background if mode == "background"
  return current.steps if has_current
  return []
end

def has_argument?(step: Step) -> Bool
  case step.argument
    Argument.NoArgument -> return false
    _ -> return true
  end
end

def read_table(src: Source, start: Int) -> Outcome[Table]
  rows: List[TableRow] = []
  width = 0
  cursor = start
  while cursor < src.texts.size and src.texts[cursor].start_with?("|")
    where = location(src, cursor)
    cells = table_row(src.texts[cursor])
    return Outcome.Failed(problem("PARSE-GHERKIN-TABLE", cells.message, where)) if not cells.ok?
    found = cells.unwrap!
    if rows.size == 0
      width = found.size
    end
    if found.size != width
      return Outcome.Failed(problem("PARSE-GHERKIN-TABLE", "table rows must have the same width", where))
    end
    rows = rows.push(TableRow(span: where, cells: found))
    cursor += 1
  end
  return Outcome.Done(Table(rows: rows, next: cursor))
end

# Each content line loses the opening line's indentation, at most.
def read_doc(src: Source, start: Int) -> Outcome[Doc]
  where = location(src, start)
  opening = src.texts[start]
  indent = String.index_of(src.raws[start], opening).unwrap_or(0)
  if not doc_delimiter?(opening)
    return Outcome.Failed(problem("PARSE-GHERKIN-ARGUMENT", "invalid Doc String delimiter", where))
  end
  cursor = start + 1
  while cursor < src.texts.size and src.texts[cursor] != "\"\"\""
    cursor += 1
  end
  if cursor >= src.texts.size
    return Outcome.Failed(problem("PARSE-GHERKIN-ARGUMENT", "unterminated Doc String", where))
  end
  content = src.raws.take(cursor).drop(start + 1).map do |value|
    blanks = blank_prefix(value)
    return rest_of(value, indent) if indent < blanks
    rest_of(value, blanks)
  end

  return Outcome.Done(Doc(text: content.join("\n"), next: cursor + 1))
end

def table_row(row: String) -> Result[List[String]]
  return error("a table row must end with |") if not row.end_with?("|")
  body = rest_of(row, 1)
  chars = body.split("")
  ends = (0...chars.size).to_a.filter do |i| chars[i] == "|" and even_run?(chars, i) end
  starts = [0].concat(ends.map do |i| i + 1 end)
  raws = (0...ends.size).to_a.map do |k| body.slice(starts[k], ends[k] - starts[k]) end
  rest = rest_of(body, starts[ends.size])
  cells = collect(raws.concat([rest]).map(&unescape_cell))
  return cells if not cells.ok?
  return error("a table row must end with an unescaped |") if rest != ""
  return error("a table row needs at least one cell") if ends.size == 0
  return ok(cells.unwrap!.take(ends.size).map do |cell| cell.strip end)
end

def even_run?(chars: List[String], at: Int) -> Bool
  i = at
  while i > 0 and chars[i - 1] == "\\"
    i -= 1
  end
  return (at - i) % 2 == 0
end

def unescape_cell(raw: String) -> Result[String]
  parts = raw.split("\\\\").map do |part| part.replace("\\|", "|").replace("\\n", "\n") end
  return error("invalid table escape") if parts.any? do |part| part.include?("\\") end
  return ok(parts.join("\\"))
end

def collect(results: List[Result[String]]) -> Result[List[String]]
  for result in results
    return error(result.message) if not result.ok?
  end
  return ok(results.map do |result| result.unwrap! end)
end

def expand_row(draft: Draft, steps: List[Step], tags: List[String], row: ExampleRow) -> Scenario
  shown = substitute(draft.name, row.bindings)
  name = shown + row_suffix(draft.name, row)
  expanded = steps.map do |step|
    Step(
      kind: step.kind,
      text: substitute(step.text, row.bindings),
      argument: substitute_argument(step.argument, row.bindings),
      span: step.span,
    )
  end

  return Scenario(
    name: name,
    steps: expanded,
    tags: tags.concat(row.tags),
    span: draft.span,
    example: Report.Example.Row(row.span),
  )
end

# The values of the columns that the outline's name does not show, as ` (a, b)`, so every row has its own name for
# the report and `--only`. A name that shows every column gets nothing. Identical rows keep identical names; the
# report's `example` place tells them apart.
def row_suffix(name: String, row: ExampleRow) -> String
  unused = (0...row.headers.size).to_a.filter do |i| not name.include?("<#{row.headers[i]}>") end
  return "" if unused.size == 0

  values = unused.map do |i| flat(row.cells[i]) end
  return " (#{values.join(", ")})"
end

# A cell as one visible piece of a name: empty is `""`, and a control character (a line feed would break the text
# report) is written as `\n`, `\r`, `\t` or `\xNN`.
def flat(cell: String) -> String
  return "\"\"" if cell == ""

  return cell.split("").map do |c| flat_char(c) end.join("")
end

def flat_char(c: String) -> String
  code = c.code
  if code == 10
    return "\\n"
  elsif code == 13
    return "\\r"
  elsif code == 9
    return "\\t"
  elsif code < 32 or code == 127
    digits = "0123456789abcdef"
    return "\\x#{digits.slice(code / 16, 1)}#{digits.slice(code % 16, 1)}"
  end

  return c
end

def substitute_argument(argument: Argument, bindings: Map[String, String]) -> Argument
  case argument
    Argument.DocString(text) -> return Argument.DocString(substitute(text, bindings))
    Argument.DataTable(rows) ->
      return Argument.DataTable(rows.map do |cells| cells.map do |cell| substitute(cell, bindings) end end)
    Argument.NoArgument -> return argument
  end
end

# Replaces each <name> (no < or > inside) that is a column of the Examples, from the left. Any other <...> stays as
# written, as in Cucumber: a doc string may hold `#include <stdio.h>` or HTML. So a misspelled column in a step is
# not an error here; the step then fails as undefined or ambiguous, with the text unreplaced.
def substitute(text: String, bindings: Map[String, String]) -> String
  return text if not text.include?("<")
  parts = text.split("<")
  return parts[0] + parts.drop(1).map do |part| substitute_part(part, bindings) end.join("")
end

def substitute_part(part: String, bindings: Map[String, String]) -> String
  # unwrap_or(0) keeps both a "<" with no ">" and an empty "<>" literal.
  close = part.index_of(">").unwrap_or(0)
  return "<#{part}" if close == 0
  name = part.slice(0, close)
  return "<#{part}" if not bindings.has_key?(name)
  return bindings[name] + rest_of(part, close + 1)
end
