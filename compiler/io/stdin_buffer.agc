## An editor buffer given on standard input (`agentica check --stdin FILE`): the text of one file that the disk may not
## have, or may hold in another version. `over` puts it in a Workspace (modules/workspace.agc), so the linker and the
## stages read FILE from the buffer and every other file from the disk; the stages stay pure.
##
## The bytes come from FrontEnd.stdin_bytes, the only way the front end reads its standard input, so `agentica fmt -`
## can take them the same way.

import Overlay from "../modules/overlay"
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

## `workspace` with `buffer` as the content of `file` (modules/overlay.agc). `windows` is true on a Windows host.
export def over(workspace: Workspace.Workspace, windows: Bool, file: String, buffer: Buffer) -> Workspace.Workspace
  return Overlay.over(workspace, [Overlay.buffer(workspace, windows, file, buffer.read)])
end
