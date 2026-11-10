## The hash of a package (docs/grammar/05b-modules.md). The .agc files of the package folder and every file of its
## native/ folder (the native libraries, any name but a dotfile, Thumbs.db and desktop.ini), with paths relative to it
## and written with "/", are taken in bytewise order of their paths; for each one the stream holds its path, a zero
## byte, its size in decimal, a zero byte and its bytes. The agentica.toml at the root joins them when native/ holds a
## file that is not .agc or the manifest has a [native] table, because the manifest then decides which file is opened;
## for any other package it is not hashed, so those hashes did not change. The hash is `sha256:` and the SHA-256 of
## that stream in hex. Hidden folders and _build/ (any depth) and agc_libs/ and deps/ (at the root) are left out:
## _build/ holds what agentica writes (its caches, or a clone a program keeps there) and deps/ the installed packages,
## so a big tree there is never walked on a start. A symbolic link named *.agc, named native at the root or inside
## native/ is refused, as the fetch refuses it, and so is a FIFO, a socket or a device under a name the hash covers;
## other links, and other files that are not .agc, are ignored.
##
## The names `.agc`, `agc_libs`, `_build` and `deps` are compared without regard to case, so `x.AGC` is hashed and
## `AGC_LIBS/` is left out on every system. A case-insensitive file system (macOS, Windows) can open `x.AGC` or
## `AGC_LIBS/y.agc` by the lowercase name, and the hash must cover what a build can load; on Linux those files are
## hashed or left out the same way and simply cannot be imported.
##
## The folder is listed and read through the Workspace. The stream is built in memory (the pieces of the files are
## collected and joined once) and hashed once with OpenSSL.Digest.sha256, so the cost is the size of the .agc files.

import Paths from "../modules/import_path"
import Workspace from "../modules/workspace"
import Toml from "std/toml"

# The folder of a package that holds its native libraries, and the manifest at its root.
NATIVE_FOLDER = "native"
MANIFEST_FILE = "agentica.toml"
# The folders left out at the root of a package (libraries, installed packages) and at any depth (agentica's caches).
LIBS_FOLDER = "agc_libs"
DEPS_FOLDER = "deps"
BUILD_FOLDER = "_build"
# Files that a file manager adds to a folder: not part of the package, so they are not hashed or copied.
NATIVE_JUNK = Set.new(["thumbs.db", "desktop.ini"])
## The most a file of a package may hold, and all its files together: a fetch copies no more (package_tree.agc), and
## the build of a fetched package reads no more (native_build.agc). The VM keeps at most 1 MiB of the output of a child
## that was not read yet (site/content/library/io-and-system/process.md), and a file is a list of bytes in memory.
export MAX_FILE_BYTES = 1_048_576
export MAX_TOTAL_BYTES = 16_777_216
# The separator of the fields of a file's header in the hashed stream. A string literal has no escape for it.
NUL = String.from_code(0)

## What hashing a folder gives: the hash, a link among the .agc files (its path), or the system's message for a file
## or folder that cannot be read.
export enum Hashed
  Hash(String)
  Link(String)
  Unreadable(String)
end

## The .agc files of a folder, or the reason it cannot be hashed.
export enum Listing
  Files(List[String])
  Stopped(Hashed)
end

## Hashes the package folder.
export def hash_folder(workspace: Workspace.Workspace, root: String) -> Hashed
  case covered_files(workspace, root)
    Listing.Stopped(reason) -> reason
    Listing.Files(paths) -> hash_files(workspace, root, paths)
  end
end

## Every file the hash of the package folder covers, in the order of the stream: its .agc files, the files of its
## native/ and, when the hash covers it, its agentica.toml.
export def covered_files(workspace: Workspace.Workspace, root: String) -> Listing
  case list_files(workspace, root)
    Listing.Stopped(reason) -> Listing.Stopped(reason)
    Listing.Files(paths) ->
      covered = paths
      if manifest_hashed?(workspace, root, paths)
        covered = covered.push(MANIFEST_FILE)
      end

      Listing.Files(covered.sort)
  end
end

## The hash of files already read: `paths` in the order of covered_files and the bytes of each, at the same index.
export def stream_hash(paths: List[String], contents: List[Bytes]) -> String
  # The pieces are joined once at the end: appending each file to the stream would copy the whole stream once for
  # each file.
  pieces: List[Bytes] = []
  for index in 0...paths.size
    pieces = pieces.concat([header(paths[index], contents[index].size), contents[index]])
  end

  "sha256:#{OpenSSL.Digest.sha256_hexdigest(Bytes.concat(pieces))}"
end

## Whether the hash of the package folder covers its agentica.toml: the file is a regular file at the root and the
## package has a file in native/ that is not .agc (`paths` are its covered files) or a top-level `native` table. A
## manifest that cannot be read or parsed is left out; the build reports it where it reads it.
export def manifest_hashed?(workspace: Workspace.Workspace, root: String, paths: List[String]) -> Bool
  entries = workspace.list_folder.call(root)
  return false if !entries.ok?

  present = entries.unwrap!.any? do |entry: Workspace.Entry| entry.name == MANIFEST_FILE and regular?(entry.kind) end
  return false if !present

  return true if paths.any? do |path: String| native_path?(path) and !source_file?(path) end

  read = workspace.read_bytes.call(join(root, MANIFEST_FILE))
  return false if !read.ok?

  text = String.from_bytes(read.unwrap!)
  return false if !text.ok?

  parsed = Toml.parse(text.unwrap!)
  return false if !parsed.ok?

  case parsed.unwrap!
    Toml.Value.Table(table) -> table.has_key?("native")
    _ -> false
  end
end

## The relative paths of the .agc files the hash covers (`vendor` copies them), walking the folders with an explicit
## stack.
export def list_files(workspace: Workspace.Workspace, root: String) -> Listing
  files: List[String] = []
  pending = [""]
  while pending.size > 0
    folder = pending[pending.size - 1]
    pending = pending.take(pending.size - 1)
    entries = workspace.list_folder.call(join(root, folder))
    return Listing.Stopped(Hashed.Unreadable(entries.message)) if !entries.ok?

    for entry in entries.unwrap!
      path = join(folder, entry.name)
      case entry.kind
        Workspace.EntryKind.Directory ->
          if !skipped_folder?(entry.name, folder == "")
            pending = pending.push(path)
          end

        Workspace.EntryKind.Link ->
          if source_file?(entry.name) or native_path?(path) or native_root?(path)
            return Listing.Stopped(Hashed.Link(path))
          end

        Workspace.EntryKind.File ->
          if covered?(entry.name, path)
            files = files.push(path)
          end

        # A FIFO, a socket or a device under a name the hash covers: reading it could wait or give bytes that are not
        # the package's.
        Workspace.EntryKind.Other ->
          return Listing.Stopped(Hashed.Unreadable("#{path} is not a regular file")) if covered?(entry.name, path)
      end
    end
  end

  Listing.Files(files)
end

## Whether a file name is a source file of a package: it ends in `.agc`, in any case.
export def source_file?(name: String) -> Bool = fold(name).ends_with?(".agc")

## Whether a path of the package (parts joined by "/") is under its native/ folder, whose files are all part of the
## package. The name is compared without regard to case, as agc_libs is.
export def native_path?(path: String) -> Bool
  parts = path.split("/")
  parts.size > 1 and fold(parts[0]) == NATIVE_FOLDER
end

## The covered files of native/ (relative paths, in bytewise order), none when the folder cannot be listed.
export def native_files(workspace: Workspace.Workspace, root: String) -> List[String]
  case list_files(workspace, root)
    Listing.Files(paths) ->
      natives = paths.filter do |path: String| native_path?(path) end
      natives.sort
    Listing.Stopped(_) -> []
  end
end

## Whether the path is the native/ entry of the package root itself (a link named so would hide a folder from the
## hash).
export def native_root?(path: String) -> Bool = fold(path) == NATIVE_FOLDER

## Whether a file name under native/ is left out: a dotfile (.DS_Store) or one that Windows adds.
export def native_junk?(name: String) -> Bool = name.starts_with?(".") or NATIVE_JUNK.include?(fold(name))

## Whether a folder is left out of the hash, and cannot be imported: a hidden one or _build at any depth, or agc_libs
## or deps at the root of the package (`top`). The names are folded, as for agc_libs, because a case-insensitive file
## system opens `_BUILD/x.agc` as `_build/x.agc`. The walks of a project (check, test) compare _build and deps exactly.
export def skipped_folder?(name: String, top: Bool) -> Bool
  folded = fold(name)
  name.starts_with?(".") or folded == BUILD_FOLDER or (top and (folded == LIBS_FOLDER or folded == DEPS_FOLDER))
end

## Whether a folder is agc_libs, in any case.
export def libs_folder?(name: String) -> Bool = fold(name) == LIBS_FOLDER

## The name without its case, for comparing it with a fixed name. Upper then lower case, so that a letter that has no
## lowercase form of its own (such as the long s, which a case-insensitive file system folds to S) is folded too.
export def fold(name: String) -> String = name.upcase.downcase

# Whether the hash covers the regular file `path` (named `name`): a source file, or a file of native/ that is not junk.
def covered?(name: String, path: String) -> Bool = source_file?(name) or (native_path?(path) and !native_junk?(name))

def regular?(kind: Workspace.EntryKind) -> Bool
  case kind
    Workspace.EntryKind.File -> true
    Workspace.EntryKind.Directory -> false
    Workspace.EntryKind.Link -> false
    Workspace.EntryKind.Other -> false
  end
end

def hash_files(workspace: Workspace.Workspace, root: String, paths: List[String]) -> Hashed
  contents: List[Bytes] = []
  for path in paths
    read = workspace.read_bytes.call(Paths.join(root, path))
    return Hashed.Unreadable(read.message) if !read.ok?

    contents = contents.push(read.unwrap!)
  end

  Hashed.Hash(stream_hash(paths, contents))
end

# Joins with one "/". An empty side gives the other one, so the root folder is listed as "<root>", never "<root>/".
def join(folder: String, name: String) -> String
  return name if folder == ""

  return folder if name == ""

  "#{folder}/#{name}"
end

# path, 0, size in decimal, 0.
def header(path: String, size: Int) -> Bytes = "#{path}#{NUL}#{size}#{NUL}".bytes
