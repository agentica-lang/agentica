## The hash of a package (docs/future/45-packages.md, 45.6). The .agc files of the package folder, with paths relative
## to it and written with "/", are taken in bytewise order of their paths; for each one the stream holds its path, a
## zero byte, its size in decimal, a zero byte and its bytes. The hash is `sha256:` and the SHA-256 of that stream in
## hex. Hidden folders (any depth) and agc_libs/ (at the root) are left out. A symbolic link named *.agc is refused, as
## the fetch refuses it; other links, and files that are not .agc, are ignored.

import Paths from "import_path"
import Sha256 from "sha256"
import {IO_TIMEOUT_MS} from "link_env"

# The bytes read from a file at a time.
CHUNK = 262144

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
export def hash_folder(root: String) -> Hashed
  case list_files(root)
    Listing.Stopped(reason) -> return reason
    Listing.Files(paths) -> return hash_files(root, paths.sort)
  end
end

def hash_files(root: String, paths: List[String]) -> Hashed
  state = Sha256.start()
  for path in paths
    file = Paths.join(root, path)
    size = File.stat(file, IO_TIMEOUT_MS)
    if !size.ok?
      return Hashed.Unreadable(size.message)
    end
    state = Sha256.update(state, header(path, size.unwrap!.size_bytes))
    streamed = stream(state, file, size.unwrap!.size_bytes)
    if !streamed.ok?
      return Hashed.Unreadable(streamed.message)
    end
    state = streamed.unwrap!
  end
  return Hashed.Hash("sha256:#{Sha256.finish(state)}")
end

# The relative paths of the .agc files, walking the folders with an explicit stack.
def list_files(root: String) -> Listing
  files: List[String] = []
  pending = [""]
  while pending.size > 0
    folder = pending[pending.size - 1]
    pending = pending.take(pending.size - 1)
    names = Dir.list(join(root, folder), IO_TIMEOUT_MS)
    if !names.ok?
      return Listing.Stopped(Hashed.Unreadable(names.message))
    end
    for name in names.unwrap!
      path = join(folder, name)
      info = File.lstat(Paths.join(root, path), IO_TIMEOUT_MS)
      if !info.ok?
        return Listing.Stopped(Hashed.Unreadable(info.message))
      end
      kind = info.unwrap!.kind
      if kind == "directory"
        if !name.starts_with?(".") and !(folder == "" and name == "agc_libs")
          pending = pending.push(path)
        end
      elsif name.ends_with?(".agc") and kind == "link"
        return Listing.Stopped(Hashed.Link(path))
      elsif name.ends_with?(".agc") and kind == "file"
        files = files.push(path)
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
  return utf8(path).push(0).concat(utf8(size.to_s)).push(0)
end

# The bytes of the file go into the state in chunks. The size in the header is what the file had, so a file that gives
# another number of bytes is an error: the hash would not be of what was named.
def stream(state: Sha256.State, file: String, size: Int) -> Result[Sha256.State]
  opened = File.open(file, "read", IO_TIMEOUT_MS)
  if !opened.ok?
    return error(opened.message)
  end
  handle = opened.unwrap!
  after = state
  total = 0
  finished = false
  while !finished
    got = File.read_bytes(handle, CHUNK, IO_TIMEOUT_MS)
    if !got.ok?
      File.close(handle, IO_TIMEOUT_MS)
      return error(got.message)
    end
    finished = got.unwrap!.size == 0
    after = Sha256.update(after, got.unwrap!)
    total += got.unwrap!.size
  end
  File.close(handle, IO_TIMEOUT_MS)
  if total != size
    return error("#{file} changed while it was read")
  end
  return ok(after)
end

# The UTF-8 bytes of a text.
def utf8(text: String) -> List[Int]
  bytes: List[Int] = []
  for character in text.split("")
    code = String.code(character)
    if code < 128
      bytes = bytes.push(code)
    elsif code < 2048
      bytes = bytes.push(192 + code.shift_right(6)).push(128 + code.bit_and(63))
    elsif code < 65536
      bytes = bytes.push(224 + code.shift_right(12)).push(128 + code.shift_right(6).bit_and(63))
      bytes = bytes.push(128 + code.bit_and(63))
    else
      bytes = bytes.push(240 + code.shift_right(18)).push(128 + code.shift_right(12).bit_and(63))
      bytes = bytes.push(128 + code.shift_right(6).bit_and(63)).push(128 + code.bit_and(63))
    end
  end
  return bytes
end
