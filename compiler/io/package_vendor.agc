## Puts a locked package into `agc_libs/<name>/` of the project (docs/future/45-packages.md, 45.9). The files come from
## the cache folder of the commit, which `install` filled and hashed: the .agc files the hash covers and the manifest
## of the package. They are built in a hidden folder of agc_libs/, hashed against the lock, and swapped for the old
## `agc_libs/<name>/` in two renames, so a build never sees a half-written copy and a failure leaves the old copy.
##
## Nothing is written outside agc_libs/: the staging folder is made there, new and private, with names the cache gave,
## and agc_libs/ itself must be a real folder, never a link. The folder of the package is owned by `vendor`: whatever
## was there (an edited copy, a stale file, a link) is replaced by the locked files. Other entries of agc_libs/ stay.

import Paths from "../modules/import_path"
import Failure from "../modules/link_failure"
import Workspace from "../modules/workspace"
import Lock from "../packages/lock"
import PackageHash from "../packages/package_hash"
import PackageFetch from "package_fetch"
import SaveFile from "save_file"

# The deadline of one file-system call, in milliseconds.
FS_TIMEOUT_MS = 60_000
TEMP_TRIES = 5
# The manifest of a package, copied when the cache holds it as a regular file.
MANIFEST_FILE = "agentica.toml"

# What a path is, looked at without following a link: the entry in the folder that holds it.
enum Kind
  Absent
  Folder
  Link
  Other
end

## Vendors the locked package from `source` (its cache folder) into `libs`, the agc_libs/ folder of the project.
## `place` names the lock entry, for the failures about the package itself.
export def put(
  workspace: Workspace.Workspace,
  libs: String,
  source: String,
  place: PackageFetch.Place,
  locked: Lock.Locked,
) -> Result[Void]
  files = try chosen(workspace, source, place, locked)
  try prepare(workspace, libs)
  stage = try make_stage(libs)
  done = stage_and_swap(workspace, libs, stage, source, files, place, locked)
  # A staging folder that cannot be removed stays hidden in agc_libs/ and does not change the answer.
  Path.remove(stage, FS_TIMEOUT_MS)
  return done
end

# The paths to copy: the .agc files of the hash, and the manifest.
def chosen(
  workspace: Workspace.Workspace,
  source: String,
  place: PackageFetch.Place,
  locked: Lock.Locked,
) -> Result[List[String]]
  listing = PackageHash.list_files(workspace, source)
  case listing
    PackageHash.Listing.Stopped(reason) -> return error(unreadable(place, source, locked, reason))
    PackageHash.Listing.Files(paths) ->
      entries = workspace.list_folder.call(source)
      if !entries.ok?
        return error(PackageFetch.fail(place, "PKG-FETCH", "", "cannot read #{source}", entries.message))
      end
      chosen = paths.sort
      for entry in entries.unwrap!
        if entry.name == MANIFEST_FILE and regular?(entry.kind)
          chosen = chosen.push(entry.name)
        end
      end
      return ok(chosen)
  end
end

def unreadable(place: PackageFetch.Place, source: String, locked: Lock.Locked, reason: PackageHash.Hashed) -> String
  case reason
    PackageHash.Hashed.Link(path) ->
      return PackageFetch.fail(place, "PKG-SYMLINK", "", "#{locked.name} has a symbolic link named #{path}", "")
    PackageHash.Hashed.Unreadable(message) ->
      return PackageFetch.fail(place, "PKG-FETCH", "", "cannot read #{source}", message)
    PackageHash.Hashed.Hash(_) -> return PackageFetch.fail(place, "PKG-FETCH", "", "cannot read #{source}", "")
  end
end

def regular?(kind: Workspace.EntryKind) -> Bool
  case kind
    Workspace.EntryKind.File -> return true
    _ -> return false
  end
end

# agc_libs/ must be a folder of the project that is not a link, else the writes below could land outside it.
def prepare(workspace: Workspace.Workspace, libs: String) -> Result[Void]
  kind = try kind_of(workspace, libs)
  case kind
    Kind.Absent ->
      made = Dir.mkdir(libs, FS_TIMEOUT_MS)
      if !made.ok?
        return error(write_failure(libs, "cannot make #{libs}", made.message))
      end
      return ok()
    Kind.Folder -> return ok()
    Kind.Link ->
      help = Failure.hint("vendor writes only inside agc_libs/; make it a folder")
      return error(Failure.fail_file(libs, "PKG-SYMLINK", "#{libs} is a symbolic link", help))
    Kind.Other -> return error(write_failure(libs, "#{libs} is not a folder", "remove it, then run vendor again"))
  end
end

def kind_of(workspace: Workspace.Workspace, path: String) -> Result[Kind]
  entries = workspace.list_folder.call(Paths.directory_of(path))
  if !entries.ok?
    return error(write_failure(path, "cannot read the folder of #{path}", entries.message))
  end
  name = Paths.last_part(path)
  for entry in entries.unwrap!
    if entry.name == name
      case entry.kind
        Workspace.EntryKind.Directory -> return ok(Kind.Folder)
        Workspace.EntryKind.Link -> return ok(Kind.Link)
        _ -> return ok(Kind.Other)
      end
    end
  end
  return ok(Kind.Absent)
end

# A new folder that only this process uses: mkdir_private fails when the name exists, so two vendors never share one.
def make_stage(libs: String) -> Result[String]
  failure = "no free name"
  for attempt in 0...TEMP_TRIES
    name = Paths.join(libs, ".tmp-#{System.pid()}-#{Random.int(0, 999_999_999)}")
    made = Dir.mkdir_private(name, FS_TIMEOUT_MS)
    if made.ok?
      return ok(name)
    end
    failure = made.message
  end
  return error(write_failure(libs, "cannot make a folder in #{libs}", failure))
end

def stage_and_swap(
  workspace: Workspace.Workspace,
  libs: String,
  stage: String,
  source: String,
  files: List[String],
  place: PackageFetch.Place,
  locked: Lock.Locked,
) -> Result[Void]
  for path in files
    try copy(workspace, source, stage, path)
  end
  case PackageHash.hash_folder(workspace, stage)
    PackageHash.Hashed.Hash(found) ->
      if found != locked.hash
        message = "the files of #{locked.name} in the cache are not the ones the lock names"
        help = "remove the cache folder and run install"
        return error(PackageFetch.fail(place, "PKG-HASH-MISMATCH", "hash", message, help))
      end
    PackageHash.Hashed.Link(path) ->
      return error(PackageFetch.fail(place, "PKG-SYMLINK", "", "#{locked.name} has a symbolic link named #{path}", ""))
    PackageHash.Hashed.Unreadable(message) ->
      return error(write_failure(stage, "cannot read the copy of #{locked.name}", message))
  end
  return swap(workspace, libs, stage, locked.name)
end

def copy(workspace: Workspace.Workspace, source: String, stage: String, path: String) -> Result[Void]
  from = Paths.join(source, path)
  to = Paths.join(stage, path)
  read = workspace.read_bytes.call(from)
  if !read.ok?
    return error(write_failure(from, "cannot read #{from}", read.message))
  end
  made = Dir.mkdir(Paths.directory_of(to), FS_TIMEOUT_MS)
  if !made.ok?
    return error(write_failure(to, "cannot make the folder of #{to}", made.message))
  end
  written = SaveFile.bytes(to, read.unwrap!, FS_TIMEOUT_MS)
  if !written.ok?
    return error(write_failure(to, "cannot write #{to}", written.message))
  end
  return ok()
end

# The old folder, a link or a file of that name is moved aside first (Path.rename never replaces), the staged folder
# takes its place, and the old one is removed. A rename that fails puts the old one back.
def swap(workspace: Workspace.Workspace, libs: String, stage: String, name: String) -> Result[Void]
  target = Paths.join(libs, name)
  backup = Paths.join(libs, ".old-#{System.pid()}-#{name}")
  seen = try kind_of(workspace, target)
  replacing = !absent?(seen)
  if replacing
    moved = Path.rename(target, backup, FS_TIMEOUT_MS)
    if !moved.ok?
      return error(write_failure(target, "cannot replace #{target}", moved.message))
    end
  end
  placed = Path.rename(stage, target, FS_TIMEOUT_MS)
  if !placed.ok?
    if replacing
      Path.rename(backup, target, FS_TIMEOUT_MS)
    end
    return error(write_failure(target, "cannot write #{target}", placed.message))
  end
  if replacing
    # The new copy stands; an old one that cannot be removed is only a spare hidden folder.
    Path.remove(backup, FS_TIMEOUT_MS)
  end
  return ok()
end

def absent?(kind: Kind) -> Bool
  case kind
    Kind.Absent -> return true
    _ -> return false
  end
end

def write_failure(file: String, message: String, reason: String) -> String
  return Failure.fail_file(file, "PKG-WRITE", message, Failure.hint(reason))
end
