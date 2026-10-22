## Resolves the packages of a project (docs/future/45-packages.md, 45.9): the list of lock entries for `add` and
## `update`. It starts from the dependencies of the manifest and follows the manifest of each package it settles, so
## the result holds every package of the build, direct or not, and only those: a package that nothing asks for any more
## is dropped. A package is settled in one of two ways. A locked entry with the same source is kept (its files are put
## in the cache if they are missing, with no git when they are there). Anything else is fetched afresh: a name the lock
## lacks, a new source, and the tag pins that `update` was asked to move. The exception is a package that is a member
## of the workspace of the project (packages/members.agc): it is locked as a member and never fetched, and its manifest
## is read from the member's folder. The files of every other settled package are in the cache when this returns,
## because the manifest of a package is read from there.

import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import GitSource from "../packages/git_source"
import Lock from "../packages/lock"
import Manifest from "../packages/manifest"
import Members from "../packages/members"
import PackageCache from "../packages/package_cache"
import Reader from "../packages/toml_read"
import PackageFetch from "package_fetch"

MANIFEST_FILE = "agentica.toml"

## Which tag pins are fetched again: every one (`all`), or the one of the package called `name` ("" for none). A
## commit (`ref`) cannot move, so it is never fetched again while the lock holds it.
export struct Refresh
  all: Bool
  name: String
end

# A package some manifest asks for, and the file of that manifest (the project's, or the cached one of a package).
struct Wanted
  name: String
  source: GitSource.Source
  asked_in: String
end

## The lock entries of `manifest` and everything it needs, with `old` as the lock to start from and `members` the
## workspace of the project. The first failure stops it. A failure names the manifest that asked for the package
## (`dependencies.<name>`), or the lock entry that was kept.
export def resolve(
  settings: Env.Settings,
  manifest: Manifest.Manifest,
  members: Members.Members,
  old: Lock.Lock,
  refresh: Refresh,
) -> Result[List[Lock.Locked]]
  cache = try PackageFetch.cache_root(settings.env, old.file)
  queue = manifest.dependencies.map do |dependency|
    Wanted(name: dependency.name, source: dependency.source, asked_in: manifest.file)
  end
  found: Map[String, Lock.Locked] = {}
  at = 0
  # A name is settled once, so the queue grows only by the dependencies of a name seen for the first time.
  while at < queue.size
    wanted = queue[at]
    at += 1
    if found.has_key?(wanted.name)
      try agree(found[wanted.name], wanted)
      next
    end
    locked = try settle(settings, cache, members, old, refresh, wanted)
    found = found.put(wanted.name, locked)
    more = try asked_by(settings, cache, members, locked)
    queue = queue.concat(more)
  end
  return ok(found.values)
end

# One name must stand for one source in a build, whoever asks for it.
def agree(locked: Lock.Locked, wanted: Wanted) -> Result[Void]
  if GitSource.same?(locked.source, wanted.source)
    return ok()
  end
  asked = GitSource.describe(wanted.source)
  message = "#{wanted.name} is #{asked}, but another package has it at #{GitSource.describe(locked.source)}"
  help = Failure.hint("one name stands for one source in a build: make the manifests agree")
  path = Reader.child("dependencies", wanted.name)
  return error(Failure.fail_key(wanted.asked_in, path, "PKG-SOURCE-CONFLICT", message, help))
end

# A member of the workspace is locked as one, with no fetch. Else keeps the locked entry when it is the same source and
# nobody asked to move it (an entry locked as a member, but not a member any more, is fetched), else fetches the pin.
def settle(
  settings: Env.Settings,
  cache: String,
  members: Members.Members,
  old: Lock.Lock,
  refresh: Refresh,
  wanted: Wanted,
) -> Result[Lock.Locked]
  if Members.member?(members, wanted.source)
    return ok(Lock.Locked(name: wanted.name, source: wanted.source, commit: "", hash: "", member: true))
  end
  for index in 0...old.packages.size
    locked = old.packages[index]
    same = locked.name == wanted.name and GitSource.same?(locked.source, wanted.source)
    if same and !locked.member and !moves?(refresh, wanted)
      place = PackageFetch.Place(file: old.file, entry: Reader.item("package", index))
      try PackageFetch.fill(settings.workspace, cache, place, locked)
      return ok(locked)
    end
  end
  place = PackageFetch.Place(file: wanted.asked_in, entry: Reader.child("dependencies", wanted.name))
  return PackageFetch.resolve(settings.workspace, cache, place, wanted.name, wanted.source)
end

def moves?(refresh: Refresh, wanted: Wanted) -> Bool
  return wanted.source.tag != "" and (refresh.all or refresh.name == wanted.name)
end

# The dependencies in the manifest of a package that is in the cache (or in the folder of a member); none when it has
# no manifest.
def asked_by(
  settings: Env.Settings,
  cache: String,
  members: Members.Members,
  locked: Lock.Locked,
) -> Result[List[Wanted]]
  folder = Members.folder_of(members, locked.source)
  if !locked.member
    folder = PackageCache.folder(cache, locked.source, locked.commit)
  end
  file = Paths.join(folder, MANIFEST_FILE)
  if !settings.workspace.file_exists.call(file)
    return ok([])
  end
  manifest = try Manifest.read(settings.workspace, file)
  return ok(
    manifest.dependencies.map do |dependency|
      Wanted(name: dependency.name, source: dependency.source, asked_in: file)
    end,
  )
end
