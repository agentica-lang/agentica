## What the fetch copies from a commit (docs/future/45-packages.md, 45.8): the `.agc` files of the package and its
## agentica.toml, chosen from the listing that `git ls-tree -r -z -l` gives. The rules of the hash decide which files
## count (package_hash.agc), so the copy holds what the hash covers and nothing else. This reads text and does no I/O.

import PackageHash from "package_hash"

# The manifest of a package, at the root of the commit.
MANIFEST_FILE = "agentica.toml"

# The end of a record of `git ls-tree -z`. A string literal has no escape for it.
NUL = String.from_bytes([0]).unwrap!

COLLISION_HELP = "rename one of them, so that the package works on a case-insensitive file system"

# The modes of git that are not a regular file: a symbolic link and a gitlink (a submodule).
LINK_MODES = Set.new(["120000", "160000"])

## One file to copy: its path in the package and the id of its blob.
export struct Blob
  path: String
  oid: String
end

## Why a fetch stops. `code` is the PKG- code; `key` is the key of the lock entry it concerns ("" for the entry as a
## whole), so the caller can name the file and the key path.
export struct Fault
  code: String
  key: String
  message: String
  help: String
end

## The files to copy, or the reason the commit cannot be a package.
export enum Plan
  Files(List[Blob])
  Refused(Fault)
end

# One line of the listing: the fields before the tab, and the path.
struct Line
  mode: String
  oid: String
  path: String
end

## Chooses the files to copy from the listing. A symbolic link or a gitlink named like a source file or the manifest is
## PKG-SYMLINK, two paths that differ only in case are PKG-PATH-COLLISION, and a path that could leave the folder is
## PKG-FETCH. Hidden folders, `agc_libs/` at the root and files that are not `.agc` are left out, as in the hash.
export def plan(listing: String) -> Plan
  chosen: List[Blob] = []
  folded: Map[String, String] = {}
  for record in listing.split(NUL)
    if record == ""
      next
    end
    line = parse(record)
    if !line.ok?
      return Plan.Refused(Fault(code: "PKG-FETCH", key: "git", message: line.message, help: ""))
    end
    found = line.unwrap!
    parts = found.path.split("/")
    if skipped?(parts)
      next
    end
    name = parts[parts.size - 1]
    if !copied?(parts, name, found.mode)
      next
    end
    if LINK_MODES.include?(found.mode)
      message = "#{found.path} is a symbolic link or a submodule"
      return Plan.Refused(refusal("PKG-SYMLINK", message, "a package holds regular files only"))
    elsif !safe?(parts)
      return Plan.Refused(refusal("PKG-FETCH", "#{found.path} is not a safe path for a file", ""))
    end
    key = PackageHash.fold(found.path)
    if folded.has_key?(key)
      message = "#{folded[key]} and #{found.path} differ only in case"
      return Plan.Refused(refusal("PKG-PATH-COLLISION", message, COLLISION_HELP))
    end
    folded = folded.put(key, found.path)
    chosen = chosen.push(Blob(path: found.path, oid: found.oid))
  end
  return Plan.Files(chosen)
end

# `MODE SP TYPE SP OID SP... SIZE TAB PATH`.
def parse(record: String) -> Result[Line]
  tab = record.index_of("\t")
  if !tab.ok?
    return error("git ls-tree gave a line with no tab")
  end
  fields = record.slice(0, tab.unwrap!).split(" ").filter do |field: String| field != "" end
  if fields.size != 4
    return error("git ls-tree gave a line with #{fields.size} fields")
  end
  path = record.slice(tab.unwrap! + 1, record.length - tab.unwrap! - 1)
  return ok(Line(mode: fields[0], oid: fields[2], path: path))
end

# Whether the path is under a folder the hash leaves out.
def skipped?(parts: List[String]) -> Bool
  for index in 0...(parts.size - 1)
    if PackageHash.skipped_folder?(parts[index], index == 0)
      return true
    end
  end
  return false
end

# Only the manifest at the root and the source files are copied. The manifest in another case is left out, unless it is
# a link: the build refuses a manifest of any case that is not a regular file, so the fetch refuses it too.
def copied?(parts: List[String], name: String, mode: String) -> Bool
  if parts.size == 1 and PackageHash.fold(name) == MANIFEST_FILE
    return name == MANIFEST_FILE or LINK_MODES.include?(mode)
  end
  return PackageHash.source_file?(name)
end

# No empty, `.` or `..` part and no backslash or colon, which a file system could read as another place.
def safe?(parts: List[String]) -> Bool
  for part in parts
    if part == "" or part == "." or part == ".." or part.contains?("\\") or part.contains?(":")
      return false
    end
  end
  return true
end

def refusal(code: String, message: String, help: String) -> Fault
  return Fault(code: code, key: "", message: message, help: help)
end
