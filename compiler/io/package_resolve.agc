## Resolves the packages of a project (docs/future/45-packages.md, 45.9): the list of lock entries for `add` and
## `update`. It starts from the dependencies of the manifest and follows the manifest of each package it settles, so
## the result holds every package of the build, direct or not, and only those: a package that nothing asks for any more
## is dropped. A package is settled in one of two ways. A locked entry with the same source is kept (its files are put
## in the cache if they are missing, with no git when they are there). Anything else is fetched afresh: a name the lock
## lacks, a new source, and the tag pins that `update` was asked to move. The files of every settled package are in the
## cache when this returns, because the manifest of a package is read from there.

import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import GitSource from "../packages/git_source"
import Lock from "../packages/lock"
import Manifest from "../packages/manifest"
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

## The lock entries of `manifest` and everything it needs, with `old` as the lock to start from. The first failure
## stops it. A failure names the manifest that asked for the package (`dependencies.<name>`), or the lock entry that
## was kept.
export def resolve(
  settings: Env.Settings,
  manifest: Manifest.Manifest,
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
    locked = try settle(settings, cache, old, refresh, wanted)
    found = found.put(wanted.name, locked)
    more = try asked_by(settings, cache, locked)
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

# Keeps the locked entry when it is the same source and nobody asked to move it, else fetches the pin.
def settle(
  settings: Env.Settings,
  cache: String,
  old: Lock.Lock,
  refresh: Refresh,
  wanted: Wanted,
) -> Result[Lock.Locked]
  for index in 0...old.packages.size
    locked = old.packages[index]
    if locked.name == wanted.name and GitSource.same?(locked.source, wanted.source) and !moves?(refresh, wanted)
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

# The dependencies in the manifest of a package that is in the cache; none when it has no manifest.
def asked_by(settings: Env.Settings, cache: String, locked: Lock.Locked) -> Result[List[Wanted]]
  file = Paths.join(PackageCache.folder(cache, locked.source, locked.commit), MANIFEST_FILE)
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
