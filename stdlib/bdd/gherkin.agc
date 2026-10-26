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
      if not tags?(line)
        return fail("PARSE-GHERKIN-TAGS", "invalid tags", where)
      end
      pending = pending.concat(split_tags(line))
      cursor += 1
    elsif heading != ""
      name = drop_blanks(rest_of(line, heading.length + 1))
      if name == "" and heading != "Examples" and heading != "Background"
        return fail("PARSE-GHERKIN-HEADER", "a section needs a name", where)
      end
      if heading == "Feature"
        if has_title
          return fail("PARSE-GHERKIN-HEADER", "one Feature is allowed per file", where)
        end
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
      if pending.size > 0
        return fail("PARSE-GHERKIN-TAGS", "tags must precede a section", where)
      end
      kind = action
      if action == "And" or action == "But"
        kind = previous
      end
      if kind == ""
        return fail("PARSE-GHERKIN-STEP", "And or But needs a preceding step", where)
      end
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
  if not has_title
    return fail("PARSE-GHERKIN-HEADER", "missing Feature", location(src, 0))
  end
  if pending.size > 0
    return fail("PARSE-GHERKIN-TAGS", "tags without a section", location(src, 0))
  end
  if not has_current
    return fail("PARSE-GHERKIN-EMPTY", "Feature needs at least one scenario", title_span)
  end
  if has_background and background.size == 0
    return fail("PARSE-GHERKIN-EMPTY", "Background needs steps", title_span)
  end
  drafts = drafts.push(current)
  scenarios: List[Scenario] = []
  for draft in drafts
    if draft.steps.size == 0
      return fail("PARSE-GHERKIN-EMPTY", "Scenario needs steps", draft.span)
    end
    if draft.outline and draft.examples.size == 0
      return fail("PARSE-GHERKIN-EXAMPLES", "Scenario Outline needs Examples", draft.span)
    end
    steps = background.concat(draft.steps)
    tags = feature_tags.concat(draft.tags)
    if draft.outline
      for row in draft.examples
        expanded = expand_row(draft, steps, tags, row)
        if not expanded.ok?
          return fail("PARSE-GHERKIN-PARAMETER", "no value for <#{expanded.message}>", row.span)
        end
        scenarios = scenarios.push(expanded.unwrap!)
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
    if part.end_with?("\r")
      return part.slice(0, part.length - 1)
    end
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

# A step's place starts at its keyword, so a report points past the indentation.
def at_keyword(where: Report.Span, raw: String) -> Report.Span
  return Report.Span(file: where.file, line: where.line, column: blank_prefix(raw) + 1, end_column: where.end_column)
end

def rest_of(text: String, start: Int) -> String
  return text.slice(start, text.length - start)
end

def blank_prefix(text: String) -> Int
  count = 0
  for c in text.split("")
    if c != " " and c != "\t"
      return count
    end
    count += 1
  end
  return count
end

def drop_blanks(text: String) -> String
  return rest_of(text, blank_prefix(text))
end

def heading_keyword(line: String) -> String
  colon = line.index_of(":")
  if not colon.ok?
    return ""
  end
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
    if line.start_with?(prefix)
      return true
    end
  end
  return false
end

def tags?(line: String) -> Bool
  for tag in line.replace("\t", " ").split(" ")
    if tag != "" and (tag.length < 2 or not tag.start_with?("@"))
      return false
    end
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
    if not allowed.include?(c)
      return false
    end
  end
  return true
end

def unique_names?(names: List[String]) -> Bool
  seen: Map[String, Bool] = {}
  for name in names
    if name == "" or seen.has_key?(name)
      return false
    end
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
  if mode == "background"
    return background
  end
  if has_current
    return current.steps
  end
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
    if not cells.ok?
      return Outcome.Failed(problem("PARSE-GHERKIN-TABLE", cells.message, where))
    end
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
    if indent < blanks
      return rest_of(value, indent)
    end
    rest_of(value, blanks)
  end
  return Outcome.Done(Doc(text: content.join("\n"), next: cursor + 1))
end

def table_row(row: String) -> Result[List[String]]
  if not row.end_with?("|")
    return error("a table row must end with |")
  end
  body = rest_of(row, 1)
  chars = body.split("")
  ends = (0...chars.size).to_a.filter do |i| chars[i] == "|" and even_run?(chars, i) end
  starts = [0].concat(ends.map do |i| i + 1 end)
  raws = (0...ends.size).to_a.map do |k| body.slice(starts[k], ends[k] - starts[k]) end
  rest = rest_of(body, starts[ends.size])
  cells = collect(raws.concat([rest]).map(&unescape_cell))
  if not cells.ok?
    return cells
  end
  if rest != ""
    return error("a table row must end with an unescaped |")
  end
  if ends.size == 0
    return error("a table row needs at least one cell")
  end
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
  if parts.any? do |part| part.include?("\\") end
    return error("invalid table escape")
  end
  return ok(parts.join("\\"))
end

def collect(results: List[Result[String]]) -> Result[List[String]]
  for result in results
    if not result.ok?
      return error(result.message)
    end
  end
  return ok(results.map do |result| result.unwrap! end)
end

def expand_row(draft: Draft, steps: List[Step], tags: List[String], row: ExampleRow) -> Result[Scenario]
  shown = try substitute(draft.name, row.bindings)
  name = shown + row_suffix(draft.name, row)
  expanded: List[Step] = []
  for step in steps
    text = try substitute(step.text, row.bindings)
    argument = try substitute_argument(step.argument, row.bindings)
    expanded = expanded.push(Step(kind: step.kind, text: text, argument: argument, span: step.span))
  end
  return ok(
    Scenario(
      name: name,
      steps: expanded,
      tags: tags.concat(row.tags),
      span: draft.span,
      example: Report.Example.Row(row.span),
    ),
  )
end

# The values of the columns that the outline's name does not show, as ` (a, b)`, so every row has its own name for
# the report and `--only`. A name that shows every column gets nothing.
def row_suffix(name: String, row: ExampleRow) -> String
  unused = (0...row.headers.size).to_a.filter do |i| not name.include?("<#{row.headers[i]}>") end
  if unused.size == 0
    return ""
  end

  values = unused.map do |i| row.cells[i] end
  return " (#{values.join(", ")})"
end

def substitute_argument(argument: Argument, bindings: Map[String, String]) -> Result[Argument]
  case argument
    Argument.DocString(text) -> return ok(Argument.DocString(try substitute(text, bindings)))
    Argument.DataTable(rows) ->
      replaced: List[List[String]] = []
      for cells in rows
        replaced = replaced.push(try collect(cells.map do |cell| substitute(cell, bindings) end))
      end
      return ok(Argument.DataTable(replaced))
    Argument.NoArgument -> return ok(argument)
  end
end

# Replaces each <name> (no < or > inside) from the left; the error is the first unknown name.
def substitute(text: String, bindings: Map[String, String]) -> Result[String]
  if not text.include?("<")
    return ok(text)
  end
  parts = text.split("<")
  pieces = collect(parts.drop(1).map do |part| substitute_part(part, bindings) end)
  if not pieces.ok?
    return error(pieces.message)
  end
  return ok(parts[0] + pieces.unwrap!.join(""))
end

def substitute_part(part: String, bindings: Map[String, String]) -> Result[String]
  close = part.index_of(">").unwrap_or(0)
  if close == 0
    return ok("<#{part}")
  end
  name = part.slice(0, close)
  if not bindings.has_key?(name)
    return error(name)
  end
  return ok(bindings[name] + rest_of(part, close + 1))
end
