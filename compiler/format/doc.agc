## The document of the formatter and its printer (docs/future/47-formatter.md, 47.5): a Wadler-style "prettier
## printer" (Wadler, "A prettier printer", 2003), in the family of Oppen's pretty printing and Prettier's doc builders.
##
## The layout builds a `Doc` from the tree, and `render` lays it out in a width. A `Group` is flat (its soft breaks are
## spaces or nothing) when its flat text fits in the rest of the line, counting the text that follows it up to the next
## break; otherwise its breaks are newlines and its nested groups decide again. A hard break is a newline in either
## mode, and the fit check stops at it as at any newline, so a group can stay flat around the multi-line body of a
## `do` block. A comment on its own line, a heredoc body and a `BreakParent` cannot be flat, so every group around them
## breaks. A `LineSuffix` (a comment after code) is written at the end of its line; one that would pass the width goes
## on its own line above that line instead, at the line's indent. A `Below` (a comment alone on its line after code)
## goes on its own line after its line. A `Fill` packs its items greedily, breaking only the separators that must
## break.
##
## The printer keeps an explicit stack and never recurses, and an indent is written only before text, so no line ends
## in spaces.

## A piece of a document.
export enum Doc
  ## Text with no line break in it.
  Text(String)
  ## A space when its group is flat, a line break when it is not.
  Line
  ## Nothing when its group is flat, a line break when it is not.
  SoftLine
  ## Always a line break.
  HardLine
  ## The pieces in order.
  Concat(List[Doc])
  ## The pieces, two spaces deeper after each line break.
  Indent(List[Doc])
  ## The pieces, flat if they fit.
  Group(List[Doc])
  ## The first pieces when the enclosing group is broken, the second when it is flat.
  IfBreak(List[Doc], List[Doc])
  ## Text written just before the next line break: a comment after code, with its leading space.
  LineSuffix(String)
  ## Makes every enclosing group break.
  BreakParent
  ## Items and separators in turn (item, separator, item, ...), each separator flat while the next item fits.
  Fill(List[Doc])
  ## A comment alone on its line, at the indent of its line, wrapped at its words into more comment lines when it is
  ## wider than the width. It starts a line; what follows it must start the next one.
  Comment(String)
  ## A comment written on its own line after the current line, at that line's indent, wrapped as `Comment` is.
  Below(String)
  ## Lines written as they are after the next line break, with no indent added: the body of a heredoc, ending with its
  ## end line.
  After(List[String])
end

# A piece waiting on the stack, with its indent and whether its group is flat.
struct Command
  indent: Int
  flat: Bool
  doc: Doc
end

# What the printer has written: the finished lines, the line being written (without its indent while it is still
# empty), the indent it will get, and the line suffixes, heredoc bodies and comments below waiting for the next line
# break.
struct Output
  lines: List[String]
  line: String
  indent: Int
  suffixes: List[String]
  afters: List[List[String]]
  belows: List[String]
end

## Lays out `doc` in `width` columns and gives the text: lines with no trailing spaces, joined by line breaks, with a
## final line break and no empty line at the end.
export def render(doc: Doc, width: Int) -> String
  stack: List[Command] = [Command(indent: 0, flat: false, doc: doc)]
  out = Output(lines: [], line: "", indent: 0, suffixes: [], afters: [], belows: [])
  while stack.size > 0
    command = stack[stack.size - 1]
    stack = stack.take(stack.size - 1)
    indent = command.indent
    flat = command.flat
    case command.doc
      Doc.Text(text) -> out = write(out, text)
      Doc.Line ->
        if flat
          out = write(out, " ")
        else
          out = newline(out, indent, width)
        end

      Doc.SoftLine ->
        if not flat
          out = newline(out, indent, width)
        end

      Doc.HardLine -> out = newline(out, indent, width)
      Doc.Concat(parts) -> stack = push_all(stack, indent, flat, parts)
      Doc.Indent(parts) -> stack = push_all(stack, indent + 2, flat, parts)
      Doc.Group(parts) ->
        chosen = flat or fits(Command(indent: indent, flat: true, doc: command.doc), stack, width - column(out))
        stack = push_all(stack, indent, chosen, parts)
      Doc.IfBreak(broken, flat_parts) ->
        if flat
          stack = push_all(stack, indent, flat, flat_parts)
        else
          stack = push_all(stack, indent, flat, broken)
        end

      Doc.LineSuffix(text) -> out = out.with(suffixes: out.suffixes.push(text))
      Doc.BreakParent -> out = out
      Doc.Fill(parts) -> stack = fill(stack, indent, flat, parts, width - column(out))
      Doc.Comment(text) -> out = comment(out, text, indent, width)
      Doc.After(lines) -> out = out.with(afters: out.afters.push(lines))
      Doc.Below(text) -> out = out.with(belows: out.belows.push(text))
    end
  end

  done = newline(out, 0, width)
  lines = done.lines
  while lines.size > 0 and lines[lines.size - 1] == ""
    lines = lines.take(lines.size - 1)
  end

  return lines.join("\n") + "\n"
end

# Pushes the parts so that the first is on top.
def push_all(stack: List[Command], indent: Int, flat: Bool, parts: List[Doc]) -> List[Command]
  out = stack
  at = parts.size - 1
  while at >= 0
    out = out.push(Command(indent: indent, flat: flat, doc: parts[at]))
    at -= 1
  end

  return out
end

# One step of a fill: its first item flat if it fits, then its first separator flat if the item after it fits too,
# then the rest of the fill.
def fill(stack: List[Command], indent: Int, flat: Bool, parts: List[Doc], room: Int) -> List[Command]
  if parts.size == 0
    return stack
  end

  item = parts[0]
  item_flat = false
  if fits(Command(indent: indent, flat: true, doc: item), [], room)
    item_flat = true
  end

  if parts.size == 1
    return stack.push(Command(indent: indent, flat: item_flat, doc: item))
  end

  separator_flat = false
  if parts.size >= 3
    pair = Doc.Concat([item, parts[1], parts[2]])
    if fits(Command(indent: indent, flat: true, doc: pair), [], room)
      separator_flat = true
    end
  end

  rest = stack.push(Command(indent: indent, flat: flat, doc: Doc.Fill(parts.drop(2))))
  rest = rest.push(Command(indent: indent, flat: separator_flat, doc: parts[1]))
  return rest.push(Command(indent: indent, flat: item_flat, doc: item))
end

# Whether `next`, laid out flat, and what follows it on the stack up to the next line break fit in `room` columns. A
# piece that cannot be flat (an own-line comment, a heredoc body, a break parent) does not fit while it is flat; a hard
# break, or a line break of a broken piece after `next`, ends the line, so the rest fits.
def fits(next: Command, stack: List[Command], room: Int) -> Bool
  left = room
  pending: List[Command] = [next]
  rest = stack.size - 1
  while true
    if left < 0
      return false
    end

    if pending.size == 0
      if rest < 0
        return true
      end

      pending = [stack[rest]]
      rest -= 1
    end

    command = pending[pending.size - 1]
    pending = pending.take(pending.size - 1)
    flat = command.flat
    case command.doc
      Doc.Text(text) -> left -= text.length
      Doc.Line ->
        if not flat
          return true
        end

        left -= 1
      Doc.SoftLine ->
        if not flat
          return true
        end

      Doc.HardLine -> return true
      Doc.Concat(parts) -> pending = push_all(pending, command.indent, command.flat, parts)
      Doc.Indent(parts) -> pending = push_all(pending, command.indent + 2, command.flat, parts)
      Doc.Group(parts) -> pending = push_all(pending, command.indent, command.flat, parts)
      Doc.IfBreak(broken, flat_parts) ->
        if flat
          pending = push_all(pending, command.indent, command.flat, flat_parts)
        else
          pending = push_all(pending, command.indent, command.flat, broken)
        end

      Doc.LineSuffix(_) -> left = left
      Doc.BreakParent ->
        if flat
          return false
        end

      Doc.Fill(parts) -> pending = push_all(pending, command.indent, command.flat, parts)
      Doc.Comment(_) -> return not flat
      Doc.After(_) -> return not flat
      Doc.Below(_) ->
        if flat
          return false
        end
    end
  end

  return true
end

# The column after what the current line holds, counting the indent it will get.
def column(out: Output) -> Int
  if out.line == ""
    return out.indent
  end

  return out.line.length
end

# Writes text on the current line, putting its indent first when the line is still empty.
def write(out: Output, text: String) -> Output
  if text == ""
    return out
  end

  line = out.line
  if line == ""
    line = spaces(out.indent)
  end

  return out.with(line: line + text)
end

# Ends the current line: its suffixes first (one that would pass the width goes above the line), then the heredoc
# bodies waiting for this break, then the comments below it; the next line gets `indent`.
def newline(out: Output, indent: Int, width: Int) -> Output
  lines = out.lines
  line = out.line
  margin = indent_of(line)
  for suffix in out.suffixes
    if line.strip == "" or line.length + suffix.length <= width
      line = line + suffix
    else
      lines = lines.concat(wrap(suffix.strip, width - margin.length).map do |part: String| margin + part end)
    end
  end

  lines = lines.push(trim_end(line))
  for body in out.afters
    lines = lines.concat(body)
  end

  for below in out.belows
    lines = lines.concat(wrap(below, width - margin.length).map do |part: String| margin + part end)
  end

  return Output(lines: lines, line: "", indent: indent, suffixes: [], afters: [], belows: [])
end

def indent_of(line: String) -> String
  at = 0
  while at < line.length and line.slice(at, 1) == " "
    at += 1
  end

  return spaces(at)
end

# The line without the spaces at its end.
def trim_end(line: String) -> String
  stop = line.length
  while stop > 0 and line.slice(stop - 1, 1) == " "
    stop -= 1
  end

  return line.slice(0, stop)
end

def spaces(count: Int) -> String
  return List.repeat(" ", count).join("")
end

# Writes an own-line comment at `indent`, wrapped at its words when it is wider than the width; a word longer than the
# width stays whole. The comment starts a line, and its last line stays open for the break that follows it.
def comment(out: Output, text: String, indent: Int, width: Int) -> Output
  written = out
  if written.line != ""
    written = newline(written, indent, width)
  end

  written = written.with(indent: indent)
  parts = wrap(text, width - indent)
  written = write(written, parts[0])
  for part in parts.drop(1)
    written = write(newline(written, indent, width), part)
  end

  return written
end

# The lines of a comment that fit in `room` columns, each with the marker of the comment (`#` and the spaces after it).
# A comment that fits, or that has a single word, is one line. The last line has two words when they fit.
def wrap(text: String, room: Int) -> List[String]
  if text.length <= room
    return [text]
  end

  marker = marker_of(text)
  words = text.slice(marker.length, text.length - marker.length).split(" ").select do |word: String| word != "" end
  if words.size <= 1
    return [text]
  end

  rows: List[List[String]] = []
  row = [words[0]]
  for word in words.drop(1)
    if marker.length + row.join(" ").length + 1 + word.length <= room
      row = row.push(word)
    else
      rows = rows.push(row)
      row = [word]
    end
  end

  # No one-word widow: the last line takes the last word of the line before when both still fit.
  if row.size == 1 and rows.size > 0 and rows[rows.size - 1].size >= 2
    before = rows[rows.size - 1]
    moved = List.concat([before[before.size - 1]], row)
    if marker.length + moved.join(" ").length <= room
      rows = rows.take(rows.size - 1).push(before.take(before.size - 1))
      row = moved
    end
  end

  return rows.push(row).map do |words_of: List[String]| marker + words_of.join(" ") end
end

# The `#` that starts a comment and the spaces after it.
def marker_of(text: String) -> String
  at = 1
  while at < text.length and text.slice(at, 1) == " "
    at += 1
  end

  return text.slice(0, at)
end
