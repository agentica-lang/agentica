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
import Engine from "native_artifact"
import NativeArtifact from "../packages/native_artifact"
import PackageFetch from "package_fetch"

MANIFEST_FILE = "agentica.toml"
# The deadline of one downloaded artifact during resolve (the engine caps hops and bytes).
NATIVE_TIMEOUT_MS = 300_000

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

# One downloaded row with where it was declared, for fetching HOST rows with a manifest file/key context.
struct Found_artifact
  artifact: Lock.Artifact
  file: String
  row: String
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
  # Only a package that is fetched needs the cache, so a manifest of workspace members alone works with no HOME.
  cache = ""
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

    if cache == "" and !Members.member?(members, wanted.source)
      cache = try PackageFetch.cache_root(settings.env, old.file)
    end

    locked = try settle(settings, cache, members, old, refresh, wanted)
    found = found.put(wanted.name, locked)
    more = try asked_by(settings, cache, members, locked)
    queue = queue.concat(more)
  end

  return ok(found.values)
end

## The native artifacts of `manifest` and every package of `packages`: one row per alias on every system the
## manifests declare, in `found` by (package, library, system). Only the rows of this host are fetched here.
export def resolve_artifacts(
  settings: Env.Settings,
  manifest: Manifest.Manifest,
  members: Members.Members,
  packages: List[Lock.Locked],
) -> Result[List[Lock.Artifact]]
  found: Map[String, Found_artifact] = {}
  found = collect_manifest(manifest, "", found)
  cache = ""
  if packages.any? do |locked| !locked.member end
    cache = try PackageFetch.cache_root(settings.env, manifest.file)
  end

  for locked in packages
    folder = Members.folder_of(members, locked.source)
    if !locked.member
      folder = PackageCache.folder(cache, locked.source, locked.commit)
    end

    file = Paths.join(folder, MANIFEST_FILE)
    if settings.workspace.file_exists.call(file)
      declared = try Manifest.read(settings.workspace, file)
      found = collect_manifest(declared, locked.name, found)
    end
  end

  if cache == "" and found.keys.any? do |key| found[key].artifact.system == settings.env.os end
    cache = try PackageFetch.cache_root(settings.env, manifest.file)
  end

  if cache != ""
    for key in found.keys
      entry = found[key]
      if entry.artifact.system == settings.env.os
        artifact = entry.artifact
        source = NativeArtifact.Source(url: artifact.url, sha256: artifact.sha256, member: artifact.member)
        context = NativeArtifact.Context(file: entry.file, key: entry.row)
        case Engine.fetch(cache, source, context, NATIVE_TIMEOUT_MS)
          ok(_) -> next
          error(packed) -> return error(packed)
        end
      end
    end
  elsif found.keys.any? do |key| found[key].artifact.system == settings.env.os end
    place = PackageFetch.Place(file: manifest.file, entry: "native")
    message = "there is no place for the native artifact cache"
    return error(PackageFetch.fail(place, "PKG-FETCH", "", message, "set HOME or XDG_CACHE_HOME"))
  end

  return ok(found.values.map do |entry: Found_artifact| entry.artifact end)
end

# Every downloaded row of `manifest` (lock key `package_name`), in `found` by (package, library, system).
def collect_manifest(
  manifest: Manifest.Manifest,
  package_name: String,
  found: Map[String, Found_artifact],
) -> Map[String, Found_artifact]
  for library in manifest.natives
    for place in library.places
      if place.url == ""
        next
      end

      here = Reader.child("native", library.name)
      row = Reader.child(here, place.system)
      artifact = Lock.Artifact(
        package: package_name,
        library: library.name,
        system: place.system,
        url: place.url,
        sha256: place.sha256,
        member: place.member,
      )
      found = found.put(artifact_key(artifact), Found_artifact(artifact: artifact, file: manifest.file, row: row))
    end
  end

  return found
end

def artifact_key(artifact: Lock.Artifact) -> String
  sep = String.from_code(0)
  return "#{artifact.package}#{sep}#{artifact.library}#{sep}#{artifact.system}"
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
