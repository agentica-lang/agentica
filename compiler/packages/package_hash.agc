## The hash of a package (docs/grammar/05b-modules.md). The .agc files of the package folder and every file of its
## native/ folder (the native libraries, any name but a dotfile, Thumbs.db and desktop.ini), with paths relative to it
## and written with "/", are taken in bytewise order of their paths; for each one the stream holds its path, a zero
## byte, its size in decimal, a zero byte and its bytes. The agentica.toml at the root joins them when native/ holds a
## file that is not .agc or the manifest has a [native] table, because the manifest then decides which file is opened;
## for any other package it is not hashed, so those hashes did not change. The hash is `sha256:` and the SHA-256 of
## that stream in hex. Hidden folders (any depth) and agc_libs/ (at the root) are left out. A symbolic link named
## *.agc, named native at the root or inside native/ is refused, as the fetch refuses it; other links, and other
## files that are not .agc, are ignored.
##
## The names `.agc` and `agc_libs` are compared without regard to case, so `x.AGC` is hashed and `AGC_LIBS/` is left
## out on every system. A case-insensitive file system (macOS, Windows) can open `x.AGC` or `AGC_LIBS/y.agc` by the
## lowercase name, and the hash must cover what a build can load; on Linux those files are hashed or left out the same
## way and simply cannot be imported.
##
## The folder is listed and read through the Workspace. The stream is built in memory (the pieces of the files are
## collected and joined once) and hashed once with Digest.sha256, so the cost is the size of the .agc files.

import Paths from "../modules/import_path"
import Workspace from "../modules/workspace"
import Toml from "std/toml"

# The folder of a package that holds its native libraries, and the manifest at its root.
NATIVE_FOLDER = "native"
MANIFEST_FILE = "agentica.toml"
# Files that a file manager adds to a folder: not part of the package, so they are not hashed or copied.
NATIVE_JUNK = Set.new(["thumbs.db", "desktop.ini"])

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
  case list_files(workspace, root)
    Listing.Stopped(reason) -> return reason
    Listing.Files(paths) ->
      covered = paths
      if manifest_hashed?(workspace, root, paths)
        covered = covered.push(MANIFEST_FILE)
      end

      return hash_files(workspace, root, covered.sort)
  end
end

## Whether the hash of the package folder covers its agentica.toml: the file is a regular file at the root and the
## package has a file in native/ that is not .agc (`paths` are its covered files) or a top-level `native` table. A
## manifest that cannot be read or parsed is left out; the build reports it where it reads it.
export def manifest_hashed?(workspace: Workspace.Workspace, root: String, paths: List[String]) -> Bool
  entries = workspace.list_folder.call(root)
  if !entries.ok?
    return false
  end

  present = entries.unwrap!.any? do |entry: Workspace.Entry| entry.name == MANIFEST_FILE and regular?(entry.kind) end
  if !present
    return false
  end

  if paths.any? do |path: String| native_path?(path) and !source_file?(path) end
    return true
  end

  read = workspace.read_bytes.call(join(root, MANIFEST_FILE))
  if !read.ok?
    return false
  end

  text = String.from_bytes(read.unwrap!)
  if !text.ok?
    return false
  end

  parsed = Toml.parse(text.unwrap!)
  if !parsed.ok?
    return false
  end

  case parsed.unwrap!
    Toml.Value.Table(table) -> return table.has_key?("native")
    _ -> return false
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
    if !entries.ok?
      return Listing.Stopped(Hashed.Unreadable(entries.message))
    end

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
          if source_file?(entry.name) or (native_path?(path) and !native_junk?(entry.name))
            files = files.push(path)
          end

        _ -> next
      end
    end
  end

  return Listing.Files(files)
end

## Whether a file name is a source file of a package: it ends in `.agc`, in any case.
export def source_file?(name: String) -> Bool
  return fold(name).ends_with?(".agc")
end

## Whether a path of the package (parts joined by "/") is under its native/ folder, whose files are all part of the
## package. The name is compared without regard to case, as agc_libs is.
export def native_path?(path: String) -> Bool
  parts = path.split("/")
  return parts.size > 1 and fold(parts[0]) == NATIVE_FOLDER
end

## The covered files of native/ (relative paths, in bytewise order), none when the folder cannot be listed.
export def native_files(workspace: Workspace.Workspace, root: String) -> List[String]
  case list_files(workspace, root)
    Listing.Files(paths) ->
      natives = paths.filter do |path: String| native_path?(path) end
      return natives.sort
    Listing.Stopped(_) -> return []
  end
end

## Whether the path is the native/ entry of the package root itself (a link named so would hide a folder from the
## hash).
export def native_root?(path: String) -> Bool
  return fold(path) == NATIVE_FOLDER
end

## Whether a file name under native/ is left out: a dotfile (.DS_Store) or one that Windows adds.
export def native_junk?(name: String) -> Bool
  return name.starts_with?(".") or NATIVE_JUNK.include?(fold(name))
end

## Whether a folder is left out of the hash, and cannot be imported: a hidden one at any depth, or agc_libs at the root
## of the package (`top`).
export def skipped_folder?(name: String, top: Bool) -> Bool
  return name.starts_with?(".") or (top and fold(name) == "agc_libs")
end

## The name without its case, for comparing it with a fixed name. Upper then lower case, so that a letter that has no
## lowercase form of its own (such as the long s, which a case-insensitive file system folds to S) is folded too.
export def fold(name: String) -> String
  return name.upcase.downcase
end

## The pieces one after the other. Each level joins neighbours, so a byte is copied about log2(pieces) times.
export def concat_all(pieces: List[List[Int]]) -> List[Int]
  level = pieces
  while level.size > 1
    merged: List[List[Int]] = []
    index = 0
    while index < level.size
      if index + 1 < level.size
        merged = merged.push(level[index].concat(level[index + 1]))
      else
        merged = merged.push(level[index])
      end

      index += 2
    end

    level = merged
  end

  if level.size == 0
    return []
  end

  return level[0]
end

def regular?(kind: Workspace.EntryKind) -> Bool
  case kind
    Workspace.EntryKind.File -> return true
    Workspace.EntryKind.Directory -> return false
    Workspace.EntryKind.Link -> return false
    Workspace.EntryKind.Other -> return false
  end
end

def hash_files(workspace: Workspace.Workspace, root: String, paths: List[String]) -> Hashed
  # The pieces are joined at the end, in pairs level by level: appending each file to the stream would copy the whole
  # stream once for each file (a list cannot grow by a long piece in constant time).
  pieces: List[List[Int]] = []
  for path in paths
    read = workspace.read_bytes.call(Paths.join(root, path))
    if !read.ok?
      return Hashed.Unreadable(read.message)
    end

    pieces = pieces.push(header(path, read.unwrap!.size).concat(read.unwrap!))
  end

  # The workspace reads a file as a List[Int] until #805 PR 4, so the stream is converted once; its items are bytes.
  stream = Bytes.from_list(concat_all(pieces))
  if !stream.ok?
    return Hashed.Unreadable(stream.message)
  end

  return Hashed.Hash("sha256:#{Digest.sha256_hexdigest(stream.unwrap!)}")
end

# Joins with one "/". An empty side gives the other one, so the root folder is listed as "<root>", never "<root>/".
def join(folder: String, name: String) -> String
  if folder == ""
    return name
  end

  if name == ""
    return folder
  end

  return "#{folder}/#{name}"
end

# path, 0, size in decimal, 0.
def header(path: String, size: Int) -> List[Int]
  return String.to_bytes(path).push(0).concat(String.to_bytes(size.to_s)).push(0)
end
