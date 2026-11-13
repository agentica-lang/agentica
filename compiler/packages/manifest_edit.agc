## The writer of agentica.toml (docs/grammar/05b-modules.md): `add` puts one line in the text of the manifest and
## leaves every other byte alone, so the comments, the blank lines, the order of the keys and the line endings of the
## user stay. The text is not parsed or encoded again (std/toml drops comments and regroups keys). The caller reads the
## new text back with Manifest.parse before it saves it, so an odd layout that this edit cannot handle is refused
## there.

import GitSource from "git_source"

## The text with `name = { git = "...", tag = "..." }` (or `ref`, and `group = "test"` last when `test`) added to the
## [dependencies] table: after its last entry, or in a new table at the end of the file when there is none.
def add_dependency(text: String, name: String, source: GitSource.Source, test: Bool) -> String
  newline = "\n"
  if text.include?("\r\n")
    newline = "\r\n"
  end

  entry = "#{name} = #{inline_table(source, test)}"
  lines = text.split("\n")
  header = header_index(lines)
  return with_new_table(text, entry, newline) if header < 0

  at = after_last_entry(lines, header)
  # A CRLF file splits at the LF, so each of its lines keeps the CR: the new line needs one too.
  carriage = newline.slice(0, newline.length - 1)
  if at == lines.size
    # The entry is the last line, which has no line ending: it gets one, and the new line has none, as the file had.
    return lines.take(at - 1).push("#{lines[at - 1]}#{carriage}").push(entry).join("\n")
  end

  lines.take(at).push("#{entry}#{carriage}").concat(lines.drop(at)).join("\n")
end

private

HEADER = "[dependencies]"

# The values were checked (GitSource), so they hold no quote or backslash and need no escape.
def inline_table(source: GitSource.Source, test: Bool) -> String
  keys = ["git = \"#{source.git}\""]
  if source.tag != ""
    keys = keys.push("tag = \"#{source.tag}\"")
  else
    keys = keys.push("ref = \"#{source.ref}\"")
  end

  if source.subdir != ""
    keys = keys.push("subdir = \"#{source.subdir}\"")
  end

  if test
    keys = keys.push("group = \"test\"")
  end

  "{ #{keys.join(", ")} }"
end

# The line of `[dependencies]`, maybe with a comment after it; -1 when there is none.
def header_index(lines: List[String]) -> Int
  for index in 0...lines.size
    head = lines[index].strip
    if head.start_with?(HEADER)
      rest = head.slice(HEADER.length, head.length - HEADER.length).strip
      return index if rest == "" or rest.start_with?("#")
    end
  end

  -1
end

# The line after the last entry of the table that starts at `header`. The blank lines and comments after that entry
# stay before the next table, where the user put them.
def after_last_entry(lines: List[String], header: Int) -> Int
  last = header
  index = header + 1
  while index < lines.size and !lines[index].strip.start_with?("[")
    head = lines[index].strip
    if head != "" and !head.start_with?("#")
      last = index
    end

    index += 1
  end

  last + 1
end

# A new table after the text, with one blank line between them.
def with_new_table(text: String, entry: String, newline: String) -> String
  return "#{HEADER}#{newline}#{entry}#{newline}" if text.strip == ""

  body = text
  if !body.end_with?("\n")
    body = "#{body}#{newline}"
  end

  if !body.end_with?("\n#{newline}")
    body = "#{body}#{newline}"
  end

  "#{body}#{HEADER}#{newline}#{entry}#{newline}"
end
