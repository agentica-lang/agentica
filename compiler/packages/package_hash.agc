## The hash of a package (docs/future/45-packages.md, 45.6). The .agc files of the package folder, with paths relative
## to it and written with "/", are taken in bytewise order of their paths; for each one the stream holds its path, a
## zero byte, its size in decimal, a zero byte and its bytes. The hash is `sha256:` and the SHA-256 of that stream in
## hex. Hidden folders (any depth) and agc_libs/ (at the root) are left out. A symbolic link named *.agc is refused, as
## the fetch refuses it; other links, and files that are not .agc, are ignored.
##
## The folder is listed and read through the Workspace. The stream is built in memory and hashed once with
## Crypto.sha256, so the cost is the size of the .agc files of the package.

import Paths from "../modules/import_path"
import Workspace from "../modules/workspace"

## What hashing a folder gives: the hash, a link among the .agc files (its path), or the system's message for a file
## or folder that cannot be read.
export enum Hashed
  Hash(String)
  Link(String)
  Unreadable(String)
end

# The .agc files of a folder, or the reason it cannot be hashed.
enum Listing
  Files(List[String])
  Stopped(Hashed)
end

## Hashes the package folder.
export def hash_folder(workspace: Workspace.Workspace, root: String) -> Hashed
  case list_files(workspace, root)
    Listing.Stopped(reason) -> return reason
    Listing.Files(paths) -> return hash_files(workspace, root, paths.sort)
  end
end

def hash_files(workspace: Workspace.Workspace, root: String, paths: List[String]) -> Hashed
  stream: List[Int] = []
  for path in paths
    read = workspace.read_bytes.call(Paths.join(root, path))
    if !read.ok?
      return Hashed.Unreadable(read.message)
    end
    stream = stream.concat(header(path, read.unwrap!.size)).concat(read.unwrap!)
  end
  return Hashed.Hash("sha256:#{hex(Crypto.sha256(stream))}")
end

# The relative paths of the .agc files, walking the folders with an explicit stack.
def list_files(workspace: Workspace.Workspace, root: String) -> Listing
  files: List[String] = []
  pending = [""]
  while pending.size > 0
    folder = pending[pending.size - 1]
    pending = pending.take(pending.size - 1)
    entries = workspace.list_folder.call(join(root, folder))
    if !entries.ok?
      return Listing.Stopped(Hashed.Unreadable(entries.message))
    end
    for entry in entries.unwrap!
      path = join(folder, entry.name)
      case entry.kind
        Workspace.EntryKind.Directory ->
          if !entry.name.starts_with?(".") and !(folder == "" and entry.name == "agc_libs")
            pending = pending.push(path)
          end
        Workspace.EntryKind.Link ->
          if entry.name.ends_with?(".agc")
            return Listing.Stopped(Hashed.Link(path))
          end
        Workspace.EntryKind.File ->
          if entry.name.ends_with?(".agc")
            files = files.push(path)
          end
        _ -> next
      end
    end
  end
  return Listing.Files(files)
end

def join(folder: String, name: String) -> String
  if folder == ""
    return name
  end
  return "#{folder}/#{name}"
end

# path, 0, size in decimal, 0.
def header(path: String, size: Int) -> List[Int]
  return String.to_bytes(path).push(0).concat(String.to_bytes(size.to_s)).push(0)
end

def hex(digest: List[Int]) -> String
  digits = "0123456789abcdef"
  return digest.map do |byte| digits.at(byte / 16) + digits.at(byte % 16) end.join("")
end
