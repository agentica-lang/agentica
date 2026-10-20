## Questions about a path that the module loader asks the file system: a file, a folder, a symbolic link. A path that
## cannot be read is neither.

import {IO_TIMEOUT_MS} from "link_env"

## True for a path that exists and is not a folder (links are followed).
export def file?(path: String) -> Bool
  info = File.stat(path, IO_TIMEOUT_MS)
  return info.ok? and info.unwrap!.kind != "directory"
end

## True for a folder (links are followed).
export def directory?(path: String) -> Bool
  info = File.stat(path, IO_TIMEOUT_MS)
  return info.ok? and info.unwrap!.kind == "directory"
end
