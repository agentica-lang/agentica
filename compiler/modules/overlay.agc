## Text in memory that stands in for files (an editor's unsaved buffers, or the standard input of `check --stdin`):
## `over` puts any number of them in a Workspace (workspace.agc), so the linker and the stages read those files from
## the buffers and every other file from the disk, and the stages stay pure. A buffer is kept under the names its file
## answers to, computed once when it is made, so a later read does not depend on what the disk holds then.

import Paths from "import_path"
import SourceFile from "../syntax/source_file"
import Workspace from "workspace"

# The names one buffer answers to: its file as typed, as a lexical absolute path, and as the linker keys it (the
# canonical folder of the file and its name, since the file itself need not exist).
struct Names
  typed: String
  absolute: String
  key: String
end

## What a file reads as, and the names that reach it. Two buffers with one canonical `key` are one file.
export struct Buffer
  names: Names
  read: SourceFile.Read
end

## The buffer that makes `read` the content of `file`, whether or not the disk has the file. The folder of `file` is
## the base of its imports and of agentica.toml; when it does not exist, an import fails. `windows` is true on a
## Windows host.
export def buffer(workspace: Workspace.Workspace, windows: Bool, file: String, read: SourceFile.Read) -> Buffer
  return Buffer(names: names_for(workspace, windows, file), read: read)
end

## `buffers` with `added`, which replaces the buffer of the same file.
export def put(buffers: List[Buffer], added: Buffer) -> List[Buffer]
  return without_key(buffers, added.names.key).push(added)
end

## `buffers` without the buffer of `file`, if it has one: the buffer whose file has the same canonical name now, or
## that was made with `file` spelled as given (the name of a file whose folder did not exist then may have changed
## since).
export def remove(buffers: List[Buffer], workspace: Workspace.Workspace, windows: Bool, file: String) -> List[Buffer]
  key = names_for(workspace, windows, file).key
  return buffers.filter do |held: Buffer|
    held.names.key != key and held.names.typed != file and held.names.absolute != file
  end
end

## Whether some buffer is the file `file` names, whichever way it is spelled.
export def holds?(buffers: List[Buffer], workspace: Workspace.Workspace, windows: Bool, file: String) -> Bool
  key = names_for(workspace, windows, file).key
  return buffers.any? do |held: Buffer| held.names.key == key end
end

## `workspace` with the content of every buffer. A read of a buffer's file, or of its absolute or canonical path, gives
## the buffer; `file_exists` says yes and `real_path` gives the canonical path even when the disk has no such file.
export def over(workspace: Workspace.Workspace, buffers: List[Buffer]) -> Workspace.Workspace
  return workspace.with(
    read_text: as_reader() do |path: String| read_buffer(workspace, buffers, path) end,
    file_exists: as_check() do |path: String| find(buffers, path).size > 0 or workspace.file_exists.call(path) end,
    real_path: as_resolver() do |path: String| real_buffer(workspace, buffers, path) end,
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
def names_for(workspace: Workspace.Workspace, windows: Bool, file: String) -> Names
  absolute = workspace.resolve_path.call(file).unwrap_or(file)
  slashed = absolute
  if windows
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

def without_key(buffers: List[Buffer], key: String) -> List[Buffer]
  return buffers.filter do |held: Buffer| held.names.key != key end
end

# The buffer for `path`: none or one in a list.
def find(buffers: List[Buffer], path: String) -> List[Buffer]
  for held in buffers
    if path == held.names.typed or path == held.names.absolute or path == held.names.key
      return [held]
    end
  end
  return []
end

def read_buffer(workspace: Workspace.Workspace, buffers: List[Buffer], path: String) -> SourceFile.Read
  found = find(buffers, path)
  if found.size > 0
    return found[0].read
  end
  return workspace.read_text.call(path)
end

def real_buffer(workspace: Workspace.Workspace, buffers: List[Buffer], path: String) -> Result[String]
  found = workspace.real_path.call(path)
  held = find(buffers, path)
  if found.ok? or held.size == 0
    return found
  end
  return ok(held[0].names.key)
end
