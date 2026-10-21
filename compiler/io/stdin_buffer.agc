## An editor buffer given on standard input (`agentica check --stdin FILE`): the text of one file that the disk may not
## have, or may hold in another version. `over` puts it in a Workspace (modules/workspace.agc), so the linker and the
## stages read FILE from the buffer and every other file from the disk; the stages stay pure.
##
## The bytes come from FrontEnd.stdin_bytes, the only way the front end reads its standard input, so `agentica fmt -`
## can take them the same way.

import Paths from "../modules/import_path"
import SourceFile from "../syntax/source_file"
import Workspace from "../modules/workspace"

## What the standard input held: how a file reads it (its text, or the place of the first byte that is not UTF-8), and
## the text to show lines of it in a message (U+FFFD in place of each invalid byte).
export struct Buffer
  read: SourceFile.Read
  shown: String
end

## The buffer, or why the standard input could not be taken (more than the cap of the VM, or a failed read).
export enum Taken
  Got(Buffer)
  Failed(String)
end

# The names one buffer answers to: FILE as typed, as a lexical absolute path, and as the linker keys it (the canonical
# folder of FILE and its name, since FILE itself need not exist).
struct Names
  typed: String
  absolute: String
  key: String
end

## Reads all of the standard input.
export def take() -> Taken
  bytes = FrontEnd.stdin_bytes()
  if !bytes.ok?
    return Taken.Failed(bytes.message)
  end
  data = bytes.unwrap!
  read = SourceFile.decode(data)
  case read
    SourceFile.Read.Text(text) -> return Taken.Got(Buffer(read: read, shown: text))
    _ -> return Taken.Got(Buffer(read: read, shown: SourceFile.replace_invalid(data)))
  end
end

## `workspace` with `buffer` as the content of `file`. A read of `file`, or of its absolute or canonical path, gives
## the buffer; `file_exists` says yes and `real_path` gives the canonical path even when the disk has no such file. The
## folder of `file` is the base of the imports and of agentica.toml; when it does not exist, an import fails.
export def over(workspace: Workspace.Workspace, file: String, buffer: Buffer) -> Workspace.Workspace
  names = names_for(workspace, file)
  return workspace.with(
    read_text: as_reader() do |path: String| read_buffer(workspace, names, buffer, path) end,
    file_exists: as_check() do |path: String| exists?(workspace, names, path) end,
    real_path: as_resolver() do |path: String| real_buffer(workspace, names, path) end,
  )
end

# The identity of a function value: a block can only be written as the block of a call.
def as_reader(f: Fn[String, SourceFile.Read]) -> Fn[String, SourceFile.Read]
  return f
end

def as_check(f: Fn[String, Bool]) -> Fn[String, Bool]
  return f
end

def as_resolver(f: Fn[String, Result[String]]) -> Fn[String, Result[String]]
  return f
end

# On Windows Path.resolve gives `\` separators, which the path helpers split only on `/`: they are split on a copy
# with `/`, as Path.join writes them.
def names_for(workspace: Workspace.Workspace, file: String) -> Names
  absolute = workspace.resolve_path.call(file).unwrap_or(file)
  slashed = absolute
  if System.os() == "windows"
    slashed = absolute.replace("\\", "/")
  end
  found = workspace.real_path.call(absolute)
  if found.ok?
    return Names(typed: file, absolute: absolute, key: found.unwrap!)
  end
  folder = Paths.directory_of(slashed)
  if folder == ""
    folder = "."
  end
  parent = workspace.real_path.call(folder)
  if !parent.ok?
    return Names(typed: file, absolute: absolute, key: absolute)
  end
  return Names(typed: file, absolute: absolute, key: Paths.join(parent.unwrap!, Paths.last_part(slashed)))
end

def answers?(names: Names, path: String) -> Bool
  return path == names.typed or path == names.absolute or path == names.key
end

def read_buffer(workspace: Workspace.Workspace, names: Names, buffer: Buffer, path: String) -> SourceFile.Read
  if answers?(names, path)
    return buffer.read
  end
  return workspace.read_text.call(path)
end

def exists?(workspace: Workspace.Workspace, names: Names, path: String) -> Bool
  return answers?(names, path) or workspace.file_exists.call(path)
end

def real_buffer(workspace: Workspace.Workspace, names: Names, path: String) -> Result[String]
  found = workspace.real_path.call(path)
  if found.ok? or !answers?(names, path)
    return found
  end
  return ok(names.key)
end
