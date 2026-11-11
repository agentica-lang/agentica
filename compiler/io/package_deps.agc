## Writes the locked packages into `deps/<name>/` of the project (docs/grammar/05b-modules.md), one flat folder for
## each package of the build, direct or not, and removes the ones the lock dropped. This is the only place a build
## reads a package from. The files come from the cache folder of the commit, which `install` filled and hashed: the
## .agc files the hash covers and the manifest of the package (for a `subdir`, the cache folder holds that folder
## alone). They are built in a hidden folder of deps/, hashed against the lock, and swapped for the old `deps/<name>/`
## in two renames, so a build never sees a half-written copy and a failure leaves the old copy. A folder that is a real
## folder with the locked hash is left as it is.
##
## The staging folder is a private (0700) parent, and the copy is a child of it made with the ordinary mode, because
## the folder that ends up as deps/<name>/ keeps its mode through the renames and other users must read it. A killed
## command can leave a hidden `.tmp-*` or `.old-*` entry in deps/; the next command removes the ones older than ten
## minutes (a younger one may belong to a command that is still running).
##
## Nothing is written outside deps/: the staging folder is made there, new and private, with names the cache gave, and
## deps/ itself must be a real folder, never a link. The folder of a package is owned by the tool: whatever was there
## (an edited .agc file, a stale one, a link) is replaced by the locked files. A dropped package is moved aside by name
## and then removed without following links (Path.remove), so a link in its place is removed as a link. Other entries
## of deps/ stay, and the tool writes no .gitignore there: committing deps/ is the project's choice.

import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import Workspace from "../modules/workspace"
import Lock from "../packages/lock"
import PackageCache from "../packages/package_cache"
import PackageHash from "../packages/package_hash"
import Reader from "../packages/toml_read"
import PackageFetch from "package_fetch"
import SaveFile from "save_file"

# The deadline of one file-system call, in milliseconds.
FS_TIMEOUT_MS = 60_000
TEMP_TRIES = 5
# How old a hidden .tmp-* or .old-* entry of deps/ must be before the next command removes it.
LEFTOVER_SECONDS = 600
# The manifest of a package, copied when the cache holds it as a regular file.
MANIFEST_FILE = "agentica.toml"

# What a path is, looked at without following a link: the entry in the folder that holds it.
enum Kind
  Absent
  Folder
  Link
  Other
end

## Writes the locked packages into `deps`, the deps/ folder of the project, in the order given, and then removes the
## folders of the `dropped` names that are not among them. `packages` are in the order of `lock_file`, whose entries
## the failures about a package name. Every package must be in the cache already (`install`, `add` and `update` fill
## it), except a workspace member or a `path` package, which has no folder in deps/: its entry is skipped, and a
## folder of deps/ that the name has is removed like that of a dropped package.
export def sync(
  settings: Env.Settings,
  lock_file: String,
  deps: String,
  packages: List[Lock.Locked],
  dropped: List[String],
) -> Result[Void]
  workspace = settings.workspace
  try sweep(workspace, deps)
  if packages.size > 0
    cache = try PackageFetch.cache_for(settings.env, lock_file, packages)
    for index in 0...packages.size
      locked = packages[index]
      next if Lock.in_place?(locked)

      place = PackageFetch.Place(file: lock_file, entry: Reader.item("package", index))
      folder = PackageCache.folder(cache, locked.source, locked.commit)
      source = workspace.real_path.call(folder)
      return error(PackageFetch.fail(place, "PKG-FETCH", "", "cannot read #{folder}", source.message)) if !source.ok?

      try put(workspace, deps, source.unwrap!, place, locked)
    end
  end

  fetched = packages.filter do |locked| !Lock.in_place?(locked) end
  kept = Set.new(fetched.map do |locked| locked.name end)
  members = packages.filter do |locked| Lock.in_place?(locked) end
  gone = dropped.concat(members.map do |locked| locked.name end)
  for name in gone
    if !kept.include?(name)
      try remove(workspace, deps, name)
    end
  end

  ok()
end

## Writes the locked package from `source` (its cache folder) into `deps`, the deps/ folder of the project, unless its
## folder there is a real folder that already has the locked hash (a rewrite would only change the times of the files
## and make the bytecode cache miss). `place` names the lock entry, for the failures about the package itself.
export def put(
  workspace: Workspace.Workspace,
  deps: String,
  source: String,
  place: PackageFetch.Place,
  locked: Lock.Locked,
) -> Result[Void]
  return ok() if up_to_date?(workspace, deps, locked)

  files = try chosen(workspace, source, place, locked)
  try prepare(workspace, deps)
  parent = try make_stage(deps)
  done = stage_and_swap(workspace, deps, parent, source, files, place, locked)
  # A staging folder that cannot be removed stays hidden in deps/ and does not change the answer. After a swap
  # only the empty parent is left.
  _ = Path.remove(parent, FS_TIMEOUT_MS)
  done
end

# Whether deps/<name> is a folder (never a link) whose .agc files hash to the lock. Anything else, a failed look
# included, is a reason to write it again.
def up_to_date?(workspace: Workspace.Workspace, deps: String, locked: Lock.Locked) -> Bool
  here = kind_of(workspace, deps)
  return false if !here.ok? or !folder?(here.unwrap!)

  target = Paths.join(deps, locked.name)
  seen = kind_of(workspace, target)
  return false if !seen.ok? or !folder?(seen.unwrap!)

  case PackageHash.hash_folder(workspace, target)
    PackageHash.Hashed.Hash(found) -> found == locked.hash
    _ -> false
  end
end

def folder?(kind: Kind) -> Bool
  case kind
    Kind.Folder -> true
    _ -> false
  end
end

# Removes what a killed or failed command left in deps/: hidden `.tmp-*` and `.old-*` entries, which a package name
# (letters, digits and a few signs, never a leading dot) cannot be, once they are older than LEFTOVER_SECONDS by their
# own modification time (a younger one may be the staging of a command that is still running). The time is read with
# File.lstat, so a link is judged by itself, and Path.remove does not follow links. A deps/ that is not a real folder
# is left alone (the writes refuse it later). A leftover that cannot be removed or looked at stays.
def sweep(workspace: Workspace.Workspace, deps: String) -> Result[Void]
  here = try kind_of(workspace, deps)
  return ok() if !folder?(here)

  listed = workspace.list_folder.call(deps)
  return ok() if !listed.ok?

  now = Time.now_ms() / 1000
  for entry in listed.unwrap!
    if entry.name.start_with?(".tmp-") or entry.name.start_with?(".old-")
      path = Paths.join(deps, entry.name)
      info = File.lstat(path, FS_TIMEOUT_MS)
      if info.ok? and now - info.unwrap!.modified_seconds > LEFTOVER_SECONDS
        _ = Path.remove(path, FS_TIMEOUT_MS)
      end
    end
  end

  ok()
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
    PackageHash.Listing.Stopped(reason) -> error(unreadable(place, source, locked, reason))
    PackageHash.Listing.Files(paths) ->
      entries = workspace.list_folder.call(source)
      return error(PackageFetch.fail(place, "PKG-FETCH", "", "cannot read #{source}", entries.message)) if !entries.ok?

      chosen = paths.sort
      for entry in entries.unwrap!
        if entry.name == MANIFEST_FILE and regular?(entry.kind)
          chosen = chosen.push(entry.name)
        end
      end

      ok(chosen)
  end
end

def unreadable(place: PackageFetch.Place, source: String, locked: Lock.Locked, reason: PackageHash.Hashed) -> String
  case reason
    PackageHash.Hashed.Link(path) ->
      PackageFetch.fail(place, "PKG-SYMLINK", "", "#{locked.name} has a symbolic link named #{path}", "")
    PackageHash.Hashed.Unreadable(message) ->
      PackageFetch.fail(place, "PKG-FETCH", "", "cannot read #{source}", message)
    PackageHash.Hashed.Hash(_) -> PackageFetch.fail(place, "PKG-FETCH", "", "cannot read #{source}", "")
  end
end

def regular?(kind: Workspace.EntryKind) -> Bool
  case kind
    Workspace.EntryKind.File -> true
    _ -> false
  end
end

# deps/ must be a folder of the project that is not a link, else the writes below could land outside it.
def prepare(workspace: Workspace.Workspace, deps: String) -> Result[Void]
  kind = try kind_of(workspace, deps)
  case kind
    Kind.Absent ->
      made = Dir.mkdir(deps, FS_TIMEOUT_MS)
      return error(write_failure(deps, "cannot make #{deps}", made.message)) if !made.ok?

      ok()
    Kind.Folder -> ok()
    Kind.Link ->
      help = Failure.hint("install writes only inside deps/; make it a folder")
      error(Failure.fail_file(deps, "PKG-SYMLINK", "#{deps} is a symbolic link", help))
    Kind.Other -> error(write_failure(deps, "#{deps} is not a folder", "remove it, then run install again"))
  end
end

def kind_of(workspace: Workspace.Workspace, path: String) -> Result[Kind]
  entries = workspace.list_folder.call(Paths.directory_of(path))
  return error(write_failure(path, "cannot read the folder of #{path}", entries.message)) if !entries.ok?

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

  ok(Kind.Absent)
end

# A new folder that only this process uses: mkdir_private fails when the name exists, so two commands never share one.
def make_stage(deps: String) -> Result[String]
  failure = "no free name"
  for _ in 0...TEMP_TRIES
    name = Paths.join(deps, ".tmp-#{unique()}")
    made = Dir.mkdir_private(name, FS_TIMEOUT_MS)
    return ok(name) if made.ok?

    failure = made.message
  end

  error(write_failure(deps, "cannot make a folder in #{deps}", failure))
end

def unique() -> String = "#{System.pid()}-#{Random.int(0, 999_999_999)}"

def stage_and_swap(
  workspace: Workspace.Workspace,
  deps: String,
  parent: String,
  source: String,
  files: List[String],
  place: PackageFetch.Place,
  locked: Lock.Locked,
) -> Result[Void]
  # Dir.mkdir keeps the mode of an ordinary folder (0777 less the umask), unlike the private parent.
  stage = Paths.join(parent, "copy")
  made = Dir.mkdir(stage, FS_TIMEOUT_MS)
  return error(write_failure(stage, "cannot make #{stage}", made.message)) if !made.ok?

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

  swap(workspace, deps, stage, locked.name)
end

def copy(workspace: Workspace.Workspace, source: String, stage: String, path: String) -> Result[Void]
  from = Paths.join(source, path)
  to = Paths.join(stage, path)
  read = workspace.read_bytes.call(from)
  return error(write_failure(from, "cannot read #{from}", read.message)) if !read.ok?

  made = Dir.mkdir(Paths.directory_of(to), FS_TIMEOUT_MS)
  return error(write_failure(to, "cannot make the folder of #{to}", made.message)) if !made.ok?

  written = SaveFile.bytes(to, read.unwrap!, FS_TIMEOUT_MS)
  return error(write_failure(to, "cannot write #{to}", written.message)) if !written.ok?

  ok()
end

# The old folder, a link or a file of that name is moved aside first (Path.rename never replaces), the staged folder
# takes its place, and the old one is removed. A rename that fails puts the old one back.
def swap(workspace: Workspace.Workspace, deps: String, stage: String, name: String) -> Result[Void]
  target = Paths.join(deps, name)
  backup = Paths.join(deps, ".old-#{unique()}-#{name}")
  seen = try kind_of(workspace, target)
  replacing = !absent?(seen)
  if replacing
    moved = Path.rename(target, backup, FS_TIMEOUT_MS)
    return error(write_failure(target, "cannot replace #{target}", moved.message)) if !moved.ok?
  end

  placed = Path.rename(stage, target, FS_TIMEOUT_MS)
  if !placed.ok?
    if replacing
      back = Path.rename(backup, target, FS_TIMEOUT_MS)
      if !back.ok?
        message = "cannot write #{target}, and the old copy could not be put back: it is in #{backup}"
        message = "#{message} (install writes the package again from the cache)"
        return error(write_failure(target, message, "#{placed.message}; #{back.message}"))
      end
    end

    return error(write_failure(target, "cannot write #{target}", placed.message))
  end

  if replacing
    # The new copy stands; an old one that cannot be removed is only a spare hidden folder.
    _ = Path.remove(backup, FS_TIMEOUT_MS)
  end

  ok()
end

# Takes the folder (or link, or file) of a dropped package out of deps/ by a rename, then removes it. Path.remove does
# not follow links, and the rename means a build that comes in between finds the package missing, never half removed.
# A deps/ that does not exist has nothing to remove, and one that is a link is refused as `put` refuses it.
def remove(workspace: Workspace.Workspace, deps: String, name: String) -> Result[Void]
  here = try kind_of(workspace, deps)
  return ok() if absent?(here)

  try prepare(workspace, deps)
  target = Paths.join(deps, name)
  seen = try kind_of(workspace, target)
  return ok() if absent?(seen)

  backup = Paths.join(deps, ".old-#{unique()}-#{name}")
  moved = Path.rename(target, backup, FS_TIMEOUT_MS)
  return error(write_failure(target, "cannot remove #{target}", moved.message)) if !moved.ok?

  # An old folder that cannot be removed is only a spare hidden folder.
  _ = Path.remove(backup, FS_TIMEOUT_MS)
  ok()
end

def absent?(kind: Kind) -> Bool
  case kind
    Kind.Absent -> true
    _ -> false
  end
end

def write_failure(file: String, message: String, reason: String) -> String
  Failure.fail_file(file, "PKG-WRITE", message, Failure.hint(reason))
end
