## Reads the TOML files of a project, agentica.toml and agentica.lock (docs/future/45-packages.md, 45.5 and 45.6), and
## reports what is wrong with them as PKG- failures that name the file and the key path (link_failure.agc, fail_key).
## The two files share this: the manager lists the keys of a parsed table itself and rejects any it does not know,
## because a typed decode would ignore extra keys.

import Toml from "std/toml"
import Diag from "../diagnostics/diagnostic"
import Failure from "../modules/link_failure"
import Workspace from "../modules/workspace"
import Source from "../syntax/source"
import SourceFile from "../syntax/source_file"

## Whose file is read: its path and the code of its failures (PKG-MANIFEST-INVALID or PKG-LOCK-INVALID).
export struct Reading
  file: String
  code: String
end

## The text of the file, or the failure for a file that cannot be read or is not UTF-8.
export def read_text(workspace: Workspace.Workspace, reading: Reading) -> Result[String]
  case workspace.read_text.call(reading.file)
    SourceFile.Read.Text(text) -> return ok(text)
    SourceFile.Read.Invalid(at) ->
      return error(
        located(reading, at, "the file is not valid UTF-8", Failure.hint("save the file as UTF-8 text")),
      )
    SourceFile.Read.Unreadable(message) -> return error(fail(reading, "", "cannot read the file: #{message}"))
  end
end

## Parses a document. A syntax error is located at its line and column, as std/toml reports them; the root is a table.
export def parse(reading: Reading, text: String) -> Result[Map[String, Toml.Value]]
  parsed = Toml.parse(text)
  if !parsed.ok?
    return error(located(reading, position_of(text, parsed.message), parsed.message, Diag.Help.NoHelp))
  end
  return table(reading, parsed.unwrap!, "")
end

## The failure for a key path: "" is the file as a whole, which has no position to show.
export def fail(reading: Reading, key_path: String, message: String) -> String
  return fail_with(reading, key_path, message, Diag.Help.NoHelp)
end

## Like fail, with a help text.
export def fail_help(reading: Reading, key_path: String, message: String, help: String) -> String
  return fail_with(reading, key_path, message, Failure.hint(help))
end

## The path of a key inside the table at path.
export def child(path: String, key: String) -> String
  if path == ""
    return key
  end
  return "#{path}.#{key}"
end

## The path of an item of the array at path (counted from 0).
export def item(path: String, index: Int) -> String
  return "#{path}[#{index}]"
end

## The entries of a table value, or a failure that says the value at path is not a table.
export def table(reading: Reading, value: Toml.Value, path: String) -> Result[Map[String, Toml.Value]]
  case value
    Toml.Value.Table(entries) -> return ok(entries)
    _ -> return error(fail(reading, path, "expected a table"))
  end
end

## The items of an array value, or a failure.
export def array(reading: Reading, value: Toml.Value, path: String) -> Result[List[Toml.Value]]
  case value
    Toml.Value.Array(items) -> return ok(items)
    _ -> return error(fail(reading, path, "expected an array"))
  end
end

## The text of a string value, or a failure.
export def text(reading: Reading, value: Toml.Value, path: String) -> Result[String]
  case value
    Toml.Value.Str(content) -> return ok(content)
    _ -> return error(fail(reading, path, "expected a string"))
  end
end

## The number of an integer value, or a failure.
export def integer(reading: Reading, value: Toml.Value, path: String) -> Result[Int]
  case value
    Toml.Value.Int(number) -> return ok(number)
    _ -> return error(fail(reading, path, "expected an integer"))
  end
end

## Fails on the first key of a table (at path) that is not in allowed, in the order the file wrote them.
export def known_keys(
  reading: Reading,
  entries: Map[String, Toml.Value],
  allowed: List[String],
  path: String,
) -> Result[Void]
  known = Set.new(allowed)
  for key in entries.keys
    if !known.include?(key)
      known_here = "the known keys here are #{allowed.join(", ")}"
      return error(fail_help(reading, child(path, key), "unknown key", known_here))
    end
  end
  return ok()
end

# The line and column in "line L, column C: ..." as a position in text; the start of the file when the message has
# none.
def position_of(source: String, message: String) -> Source.Position
  start = Source.Position(offset: 0, line: 1, column: 1)
  pieces = message.split(": ")
  words = pieces[0].split(", ")
  if words.size != 2 or !words[0].starts_with?("line ") or !words[1].starts_with?("column ")
    return start
  end
  line = words[0].slice(5, words[0].length - 5).to_i
  column = words[1].slice(7, words[1].length - 7).to_i
  if !line.ok? or !column.ok? or line.unwrap! < 1 or column.unwrap! < 1
    return start
  end
  # The offset counts the characters before the line (each with its line feed), then the column.
  before = 0
  lines = source.split("\n")
  for index in 0...(line.unwrap! - 1)
    if index < lines.size
      before += lines[index].length + 1
    end
  end
  return Source.Position(offset: before + column.unwrap! - 1, line: line.unwrap!, column: column.unwrap!)
end

def fail_with(reading: Reading, key_path: String, message: String, help: Diag.Help) -> String
  if key_path == ""
    return Failure.fail_file(reading.file, reading.code, message, help)
  end
  return Failure.fail_key(reading.file, key_path, reading.code, message, help)
end

def located(reading: Reading, at: Source.Position, message: String, help: Diag.Help) -> String
  stop = Source.Position(offset: at.offset + 1, line: at.line, column: at.column + 1)
  site = Failure.Site(file: reading.file, span: Source.Span(start: at, stop: stop))
  return Failure.fail_at(site, reading.code, message, help)
end
