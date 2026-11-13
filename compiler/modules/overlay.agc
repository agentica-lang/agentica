## Text in memory that stands in for files (an editor's unsaved buffers, or the standard input of `check --stdin`):
## `over` puts any number of them in a Workspace (workspace.agc), so the linker and the stages read those files from
## the buffers and every other file from the disk, and the stages stay pure. A buffer is kept under the names its file
## answers to, computed once when it is made, so a later read does not depend on what the disk holds then.

import SourceFile from "../syntax/source_file"
import Paths from "import_path"
import Workspace from "workspace"

## What a file reads as, and the names that reach it. Two buffers with one canonical `key` are one file.
struct Buffer
  names: Names
  read: SourceFile.Read
end

## The buffer that makes `read` the content of `file`, whether or not the disk has the file. The folder of `file` is
## the base of its imports and of agentica.toml; when it does not exist, an import fails. `windows` is true on a
## Windows host.
def buffer(workspace: Workspace.Workspace, windows: Bool, file: String, read: SourceFile.Read) -> Buffer
  Buffer(names: names_for(workspace, windows, file), read: read)
end

## `buffers` with `added`, which replaces the buffer of the same file.
def put(buffers: List[Buffer], added: Buffer) -> List[Buffer] = without_key(buffers, added.names.key).push(added)

## `buffers` without the buffer of `file`, if it has one: the buffer whose file has the same canonical name now, or
## that was made with `file` spelled as given (the name of a file whose folder did not exist then may have changed
## since).
def remove(buffers: List[Buffer], workspace: Workspace.Workspace, windows: Bool, file: String) -> List[Buffer]
  key = names_for(workspace, windows, file).key
  buffers.filter do |held: Buffer|
    held.names.key != key and held.names.typed != file and held.names.absolute != file
  end
end

## Whether some buffer is the file `file` names, whichever way it is spelled.
def holds?(buffers: List[Buffer], workspace: Workspace.Workspace, windows: Bool, file: String) -> Bool
  key = names_for(workspace, windows, file).key
  buffers.any? do |held: Buffer| held.names.key == key end
end

## `workspace` with the content of every buffer. A read of a buffer's file, or of its absolute or canonical path, gives
## the buffer; `file_exists` says yes and `real_path` gives the canonical path even when the disk has no such file.
def over(workspace: Workspace.Workspace, buffers: List[Buffer]) -> Workspace.Workspace
  workspace.with(
    read_text: ->(path) { read_buffer(workspace, buffers, path) },
    file_exists: ->(path) { find(buffers, path).size > 0 or workspace.file_exists.call(path) },
    real_path: ->(path) { real_buffer(workspace, buffers, path) },
  )
end

private

# The names one buffer answers to: its file as typed, as a lexical absolute path, and as the linker keys it (the
# canonical folder of the file and its name, since the file itself need not exist).
struct Names
  typed: String
  absolute: String
  key: String
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
  return Names(typed: file, absolute: absolute, key: found.unwrap!) if found.ok?

  folder = Paths.directory_of(slashed)
  if folder == ""
    folder = "."
  end

  parent = workspace.real_path.call(folder)
  return Names(typed: file, absolute: absolute, key: absolute) if !parent.ok?

  Names(typed: file, absolute: absolute, key: Paths.join(parent.unwrap!, Paths.last_part(slashed)))
end

def without_key(buffers: List[Buffer], key: String) -> List[Buffer]
  buffers.filter do |held: Buffer| held.names.key != key end
end

# The buffer for `path`: none or one in a list.
def find(buffers: List[Buffer], path: String) -> List[Buffer]
  for held in buffers
    return [held] if path == held.names.typed or path == held.names.absolute or path == held.names.key
  end

  []
end

def read_buffer(workspace: Workspace.Workspace, buffers: List[Buffer], path: String) -> SourceFile.Read
  found = find(buffers, path)
  return found[0].read if found.size > 0

  workspace.read_text.call(path)
end

def real_buffer(workspace: Workspace.Workspace, buffers: List[Buffer], path: String) -> Result[String]
  found = workspace.real_path.call(path)
  held = find(buffers, path)
  return found if found.ok? or held.size == 0

  ok(held[0].names.key)
end
