## Resolves the packages of a project (docs/grammar/05b-modules.md): the list of lock entries for `add` and `update`.
## It starts from the dependencies of the manifest and follows the manifest of each package it settles, so the result
## holds every package of the build, direct or not, and only those: a package that nothing asks for any more is
## dropped. The test group of the project (`group = "test"`) is followed, and that of a package is not. A package is
## settled in one of two ways. A locked entry with the same source is kept (its files are put in the cache if they are
## missing, with no git when they are there). Anything else is fetched afresh: a name the lock lacks, a new source, and
## the tag pins that `update` was asked to move. The exception is a package that is a member of the workspace of the
## project (packages/members.agc): it is locked as a member and never fetched, and its manifest is read from the
## member's folder. A workspace dependency (`workspace = true`) is settled as a group: the entry of the workspace and
## one for each of its members, fetched together; a dependency of a member on a sibling (a folder of the same
## workspace) is the sibling's entry, whatever pin it writes, and every other dependency of a member is asked for as
## usual. The files of every other settled package are in the cache when this returns, because the manifest of a
## package is read from there.
## A dependency of the project's own manifest may be a `path` (a folder read in place, as a member is: never fetched,
## so it needs no cache) and may say `override = true`: its source then wins for that name everywhere, so a package
## that asks for another source of the name is not a conflict. The ones that did are reported (`Resolved.asked`).

import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import GitSource from "../packages/git_source"
import Lock from "../packages/lock"
import Manifest from "../packages/manifest"
import Members from "../packages/members"
import PackageCache from "../packages/package_cache"
import Project from "../packages/project"
import Reader from "../packages/toml_read"
import VersionRequirement from "../packages/version_requirement"
import Engine from "native_artifact"
import NativeArtifact from "../packages/native_artifact"
import PackageFetch from "package_fetch"

## Which tag pins are fetched again: every one (`all`), or the one of the package called `name` ("" for none); a
## `version` is read against the tags of the repository again. A commit (`ref`) cannot move, so it is never fetched
## again while the lock holds it.
struct Refresh
  all: Bool
  name: String
end

## What `resolve` found: every package of the build, and for each overridden name the packages that asked for another
## source of it (a name that no package contested is not in `asked`).
struct Resolved
  packages: List[Lock.Locked]
  asked: Map[String, List[String]]
end

## The lock entries of `manifest` and everything it needs, with `old` as the lock to start from and `members` the
## workspace of the project. The first failure stops it. A failure names the manifest that asked for the package
## (`dependencies.<name>`), or the lock entry that was kept. A package with a `version` takes one tag for the whole
## tree: when a package asks for something that the tag taken so far does not meet, the pass starts again with that
## ask added (the asks stay, whatever tags the next pass takes; there is no backtracking over the other tags), until
## one tag meets every ask or none does (PKG-VERSION-UNSATISFIED).
def resolve(
  settings: Env.Settings,
  manifest: Manifest.Manifest,
  members: Members.Members,
  old: Lock.Lock,
  refresh: Refresh,
) -> Result[Resolved]
  asks: Map[String, List[PackageFetch.Ask]] = {}
  for _ in 0...MAX_PASSES
    done = try pass(settings, manifest, members, old, refresh, asks)
    return ok(done.resolved) if !done.again

    asks = done.asks
  end

  place = PackageFetch.Place(file: manifest.file, entry: "dependencies")
  message = "the requirements of the packages move the tags for more than #{MAX_PASSES} passes"
  error(PackageFetch.fail(place, "PKG-VERSION-UNSATISFIED", "", message, ""))
end

## The native artifacts of `manifest` and every package of `packages`: one row per alias on every system the
## manifests declare, in `found` by (package, library, system). Only the rows of this host are fetched here.
def resolve_artifacts(
  settings: Env.Settings,
  manifest: Manifest.Manifest,
  members: Members.Members,
  packages: List[Lock.Locked],
) -> Result[List[Lock.Artifact]]
  found: Map[String, Found_artifact] = {}
  found = collect_manifest(manifest, "", found)
  cache = ""
  if packages.any? do |locked| !Lock.in_place?(locked) end
    cache = try PackageFetch.cache_root(settings.env, manifest.file)
  end

  dir = Paths.directory_of(manifest.file)
  for locked in packages
    next if Lock.root?(locked)

    folder = Project.folder_of(dir, members, locked)
    if !Lock.in_place?(locked)
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

  ok(found.values.map do |entry: Found_artifact| entry.artifact end)
end

private

MANIFEST_FILE = "agentica.toml"
# The most passes of `resolve`; each one but the last adds an ask, and the asks of a tree are few.
MAX_PASSES = 32
# The deadline of one downloaded artifact during resolve (the engine caps hops and bytes).
NATIVE_TIMEOUT_MS = 300_000

# A package some manifest asks for, the file of that manifest (the project's, or the cached one of a package), the
# package it belongs to ("" for the project's), whether it says `override = true` (only the project's can) and
# whether it
# is a workspace dependency.
struct Wanted
  name: String
  source: GitSource.Source
  asked_in: String
  by: String
  override: Bool
  workspace: Bool
end

# One downloaded row with where it was declared, for fetching HOST rows with a manifest file/key context.
struct Found_artifact
  artifact: Lock.Artifact
  file: String
  row: String
end

# What one pass found: whether it stopped to start again, the asks to start with, and what it resolved.
struct Pass
  again: Bool
  asks: Map[String, List[PackageFetch.Ask]]
  resolved: Resolved
end

# One walk over the dependencies of the project and of the packages it settles. It stops with `again` when a package
# asks for a tag that the one taken for its name does not meet (`reconcile`).
def pass(
  settings: Env.Settings,
  manifest: Manifest.Manifest,
  members: Members.Members,
  old: Lock.Lock,
  refresh: Refresh,
  start: Map[String, List[PackageFetch.Ask]],
) -> Result[Pass]
  asks = start
  # Only a package that is fetched needs the cache, so a manifest of workspace members and paths alone works with no
  # HOME.
  cache = ""
  dir = Paths.directory_of(manifest.file)
  queue = manifest.dependencies.map do |dependency|
    Wanted(
      name: dependency.name,
      source: dependency.source,
      asked_in: manifest.file,
      by: "",
      override: dependency.override,
      workspace: dependency.workspace,
    )
  end

  found: Map[String, Lock.Locked] = {}
  asked: Map[String, List[String]] = {}
  at = 0
  # A name is settled once, so the queue grows only by the dependencies of a name seen for the first time.
  while at < queue.size
    wanted = queue[at]
    at += 1
    asks = note_ask(asks, wanted)
    if found.has_key?(wanted.name)
      if found[wanted.name].override
        asked = note_asked(asked, found[wanted.name], wanted)
      else
        again = try reconcile(found[wanted.name], wanted, asks)
        return ok(Pass(again: true, asks: asks, resolved: Resolved(packages: [], asked: {}))) if again
      end

      next
    end

    if cache == "" and !in_place?(members, wanted.source)
      cache = try PackageFetch.cache_root(settings.env, old.file)
    end

    settled = try settle(settings, cache, members, old, refresh, wanted, asks_of(asks, wanted.name))
    for locked in settled
      found = found.put(locked.name, locked)
    end

    # The siblings of a member are in `found` by now, so they are not asked for again.
    here = Lock.Lock(file: old.file, packages: found.values, artifacts: [])
    for locked in settled
      next if Lock.root?(locked)

      queue = queue.concat(try asked_by(settings, cache, dir, members, here, locked))
    end
  end

  ok(Pass(again: false, asks: asks, resolved: Resolved(packages: found.values, asked: asked)))
end

# The asks of a name, in the order they were noted.
def asks_of(asks: Map[String, List[PackageFetch.Ask]], name: String) -> List[PackageFetch.Ask]
  return asks[name] if asks.has_key?(name)

  []
end

# Notes what a dependency asks of the tag of its name (a package in place or a workspace dependency asks nothing), once
# for each asker.
def note_ask(asks: Map[String, List[PackageFetch.Ask]], wanted: Wanted) -> Map[String, List[PackageFetch.Ask]]
  return asks if wanted.workspace or GitSource.local?(wanted.source)

  ask = PackageFetch.ask_for(wanted.source, wanted.by)
  return asks if !ask.some?

  known = asks_of(asks, wanted.name)
  return asks if known.any? do |each: PackageFetch.Ask| same_ask?(each, ask.unwrap!) end

  asks.put(wanted.name, known.push(ask.unwrap!))
end

def same_ask?(left: PackageFetch.Ask, right: PackageFetch.Ask) -> Bool
  left.tag == right.tag and left.by == right.by and VersionRequirement.same?(left.text, right.text)
end

# Whether the pass has to start again because `wanted` asks for something that the entry `locked` of its name does
# not meet. One name stands for one source, but a `version` of a package, a `version` of another and a tag that is a
# version are one source when one tag meets them all: the tag taken so far, or the one the next pass takes. A tag taken
# from a pin cannot move, so what it does not meet is PKG-VERSION-UNSATISFIED, and two different pins are
# PKG-SOURCE-CONFLICT, as everything else that differs.
def reconcile(locked: Lock.Locked, wanted: Wanted, asks: Map[String, List[PackageFetch.Ask]]) -> Result[Bool]
  return ok(false) if GitSource.same?(locked.source, wanted.source) and wanted.workspace == Lock.root?(locked)

  asked = PackageFetch.ask_for(wanted.source, wanted.by)
  held = PackageFetch.ask_for(locked.source, "")
  versioned = locked.source.version != "" or wanted.source.version != ""
  alike = GitSource.same_place?(locked.source, wanted.source) and !wanted.workspace and !Lock.root?(locked)
  if !(versioned and alike and asked.some? and held.some? and !locked.member)
    try agree(locked, wanted)
    return ok(false)
  end

  known = asks_of(asks, wanted.name)
  return ok(false) if PackageFetch.fits?(locked.source.subdir, locked.source.tag, known)
  return ok(true) if locked.source.version != ""

  key = "version"
  if wanted.source.version == ""
    key = "tag"
  end

  place = PackageFetch.Place(file: wanted.asked_in, entry: Reader.child("dependencies", wanted.name))
  help = "make the asks agree on one tag, or give the packages another name each"
  error(PackageFetch.unsatisfied(place, key, wanted.name, wanted.source, known, help))
end

# A package that is read in place and never fetched: a `path`, or a member of the workspace.
def in_place?(members: Members.Members, source: GitSource.Source) -> Bool
  GitSource.local?(source) or Members.member?(members, source)
end

# Records that the package `wanted.by` asked for a source of an overridden name other than the one that won.
def note_asked(asked: Map[String, List[String]], winner: Lock.Locked, wanted: Wanted) -> Map[String, List[String]]
  return asked if GitSource.same?(winner.source, wanted.source)

  names: List[String] = []
  if asked.has_key?(wanted.name)
    names = asked[wanted.name]
  end

  asked.put(wanted.name, names.push(wanted.by))
end

# Every downloaded row of `manifest` (lock key `package_name`), in `found` by (package, library, system).
def collect_manifest(
  manifest: Manifest.Manifest,
  package_name: String,
  found: Map[String, Found_artifact],
) -> Map[String, Found_artifact]
  for library in manifest.natives
    for place in library.places
      next if place.url == ""

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

  found
end

def artifact_key(artifact: Lock.Artifact) -> String
  sep = String.from_code(0)
  "#{artifact.package}#{sep}#{artifact.library}#{sep}#{artifact.system}"
end

# One name must stand for one source in a build, whoever asks for it, and for a package or a workspace.
def agree(locked: Lock.Locked, wanted: Wanted) -> Result[Void]
  return ok() if GitSource.same?(locked.source, wanted.source) and wanted.workspace == Lock.root?(locked)

  asked = GitSource.describe(wanted.source)
  message = "#{wanted.name} is #{asked}, but another package has it at #{GitSource.describe(locked.source)}"
  help = Failure.hint(Project.CONFLICT_HELP)
  path = Reader.child("dependencies", wanted.name)
  error(Failure.fail_key(wanted.asked_in, path, "PKG-SOURCE-CONFLICT", message, help))
end

# A `path` and a member of the workspace are locked as such, with no fetch. Else keeps the locked entry when it is the
# same source and nobody asked to move it (an entry locked as a member, but not a member any more, is fetched), else
# fetches the pin. A workspace dependency gives its own entry and the entries of its members.
def settle(
  settings: Env.Settings,
  cache: String,
  members: Members.Members,
  old: Lock.Lock,
  refresh: Refresh,
  wanted: Wanted,
  asks: List[PackageFetch.Ask],
) -> Result[List[Lock.Locked]]
  if GitSource.local?(wanted.source)
    return ok([
      Lock.Locked(
        name: wanted.name,
        source: wanted.source,
        commit: "",
        hash: "",
        member: false,
        override: wanted.override,
        repository: "",
      ),
    ])
  end

  if Members.member?(members, wanted.source)
    return ok([
      Lock.Locked(
        name: wanted.name,
        source: wanted.source,
        commit: "",
        hash: "",
        member: true,
        override: wanted.override,
        repository: "",
      ),
    ])
  end

  return settle_workspace(settings, cache, old, refresh, wanted) if wanted.workspace

  for index in 0...old.packages.size
    locked = old.packages[index]
    same = locked.name == wanted.name and GitSource.same?(locked.source, wanted.source)
    if same and !locked.member and !Lock.root?(locked) and !moves?(refresh, wanted) and keeps?(locked, asks)
      place = PackageFetch.Place(file: old.file, entry: Reader.item("package", index))
      try PackageFetch.fill(settings.workspace, cache, place, locked)
      return ok([locked.with(override: wanted.override)])
    end
  end

  place = PackageFetch.Place(file: wanted.asked_in, entry: Reader.child("dependencies", wanted.name))
  source = wanted.source
  if source.version != ""
    source = try PackageFetch.choose_tag(settings.workspace, cache, place, wanted.name, source, asks)
  end

  fetched = try PackageFetch.resolve(settings.workspace, cache, place, wanted.name, source)
  ok([fetched.with(override: wanted.override)])
end

# A workspace dependency: the locked entry of the workspace and its members when the lock has them at this source and
# nobody asked to move the pin (their files are put in the cache with one fetch if they are missing), else one fetch
# of the pin that reads the workspace table.
def settle_workspace(
  settings: Env.Settings,
  cache: String,
  old: Lock.Lock,
  refresh: Refresh,
  wanted: Wanted,
) -> Result[List[Lock.Locked]]
  for locked in old.packages
    same = locked.name == wanted.name and Lock.root?(locked) and GitSource.same?(locked.source, wanted.source)
    if same and !moves?(refresh, wanted)
      entries: List[PackageFetch.Entry] = []
      for index in 0...old.packages.size
        if Lock.namespace(old.packages[index].name) == wanted.name
          place = PackageFetch.Place(file: old.file, entry: Reader.item("package", index))
          entries = entries.push(PackageFetch.Entry(place: place, locked: old.packages[index]))
        end
      end

      if entries.size > 0
        try PackageFetch.fill_group(settings.workspace, cache, entries)
      end

      return ok(
        [locked.with(override: wanted.override)].concat(entries.map do |entry: PackageFetch.Entry| entry.locked end),
      )
    end
  end

  place = PackageFetch.Place(file: wanted.asked_in, entry: Reader.child("dependencies", wanted.name))
  fetched = try PackageFetch.resolve_workspace(settings.workspace, cache, place, wanted.name, wanted.source)
  ok([fetched[0].with(override: wanted.override)].concat(fetched.drop(1)))
end

# Whether a locked entry still meets the asks of its name: one that is not a `version` has nothing to meet.
def keeps?(locked: Lock.Locked, asks: List[PackageFetch.Ask]) -> Bool
  locked.source.version == "" or PackageFetch.fits?(locked.source.subdir, locked.source.tag, asks)
end

def moves?(refresh: Refresh, wanted: Wanted) -> Bool
  pinned = wanted.source.tag != "" or wanted.source.version != ""
  pinned and (refresh.all or refresh.name == wanted.name)
end

# The dependencies in the manifest of a package that is in the cache (or in the folder of a member or a path); none
# when it has no manifest. `dir` is the folder of the project's manifest. A package may not say `path` or `override`.
def asked_by(
  settings: Env.Settings,
  cache: String,
  dir: String,
  members: Members.Members,
  here: Lock.Lock,
  locked: Lock.Locked,
) -> Result[List[Wanted]]
  folder = Project.folder_of(dir, members, locked)
  if !Lock.in_place?(locked)
    folder = PackageCache.folder(cache, locked.source, locked.commit)
  end

  file = Paths.join(folder, MANIFEST_FILE)
  return ok([]) if !settings.workspace.file_exists.call(file)

  manifest = try Manifest.read_checked(settings.workspace, file, locked.name, settings.version)
  try Manifest.require_package(manifest)
  # The test group of a package is its own: a project that depends on it neither fetches nor locks it.
  # A sibling of a member of a workspace dependency is that workspace's own entry, not another package to settle.
  asked = Manifest.needed(manifest).select do |dependency: Manifest.Dependency|
    Lock.sibling(here, locked.name, dependency.source) == ""
  end

  ok(
    asked.map do |dependency: Manifest.Dependency|
      Wanted(
        name: dependency.name,
        source: dependency.source,
        asked_in: file,
        by: locked.name,
        override: false,
        workspace: dependency.workspace,
      )
    end,
  )
end
