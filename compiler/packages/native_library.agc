## The native libraries of a package (docs/grammar/05b-modules.md): `[native.NAME]` in its manifest says where the
## library that `extern "NAME"` means is on each system, either a file in the package's native/ folder (hashed with the
## package, so the lock covers it) or a name for the system loader. A file is turned into its absolute path, which the
## VM opens as it opens any absolute library; never a search. A `system` entry lists one or more candidates: the first
## absolute path that exists is chosen, else the first bare name, so a library the loader cannot find by name (a
## Homebrew one on macOS) is found by its path. The choice is made here, from the machine, and never written to the
## manifest or the lock, which stay the same on every machine. Only the entry of this system is looked at, and only
## when a file of the package uses the library, so a package works on the systems it names and is refused on the
## others where it is used. A package with a `build` table builds the library from its C sources instead
## (native_build.agc), whatever its system entries say, when it is read in place (the project, a workspace member, a
## `path` dependency) or fetched and pinned by its lock row (its hash, checked again before the build). This does no
## I/O of its own: it asks the Workspace.

import Paths from "../modules/import_path"
import Failure from "../modules/link_failure"
import Workspace from "../modules/workspace"
import Lock from "lock"
import Manifest from "manifest"
import NativeArtifact from "native_artifact"
import NativeBuild from "native_build"
import PackageHash from "package_hash"
import Reader from "toml_read"

## What `extern "name"` means in a file of the package: the absolute path of a file of the package, a name for the
## system loader, a module to build from its C sources when a file first uses it (the linker asks the Workspace then,
## build_target), or the packed failure to report when the file uses it.
export enum Target
  File(String)
  System(String)
  Build(Workspace.BuildRequest)
  Unusable(String)
end

## What a manifest's [native] table means on one system: the target of each library it declares, what the bytecode
## cache must watch because the program opens it, and the absolute candidates of a `system` list (probed), whose
## presence the choice depended on: the cache notes whether each exists, not what it holds. watched, for a package, is
## the folder itself (the cache digests the names of its native/ files, so an added file is seen), every file of
## native/ (a library may load others), and the manifest when the package hash covers it. For the project it is the
## declared files for this system. A package read in place that builds a module (the project too) also watches its
## folder and every file of native/ as the build walks it (NativeBuild.native_files: hidden ones too), so an edit or a
## new file there is a miss; the project's manifest is in the cache key already. A fetched package that builds watches
## the same. watched is empty when there is
## nothing to open. A built library is not known here (it is built when a file uses it); the bytecode cache watches the
## ones the program names.
export struct Found
  targets: Map[String, Target]
  watched: List[String]
  probed: List[String]
end

## The libraries a manifest declares, for the system `os` ("linux", "macos" or "windows"). `root` is the real folder of
## the package (or of the project), which holds the files. `package` is false for the project, whose files are not
## hashed; `member` is true for a workspace member or a `path` dependency, whose are not either: those and the project
## are read in place, so they build what has a `build` table. `pinned` is the locked hash of a fetched package whose
## folder the caller checked against it ("" otherwise): such a package builds too, and the build checks the hash again.
## `package_name` is the lock key of the
## package ("" for the project root), `lock` the lock to match downloaded rows against, and `cache_root` the
## package cache root ("" when no place was given): downloaded rows are verified from the cache alone and become
## a file path, never fetched.
export def resolve(
  workspace: Workspace.Workspace,
  manifest: Manifest.Manifest,
  root: String,
  os: String,
  package: Bool,
  member: Bool,
  pinned: String,
  package_name: String,
  lock: Lock.Lock,
  cache_root: String,
) -> Found
  buildable = !package or member or pinned != ""
  targets: Map[String, Target] = {}
  for library in manifest.natives
    target = target_of(workspace, manifest, library, root, os, package_name, lock, cache_root, buildable, pinned)
    targets = targets.put(library.name, target)
  end

  probed = probes(manifest, os)
  inputs: List[String] = []
  if targets.values.any? do |target: Target| build?(target) end
    inputs = [root].concat(build_inputs(workspace, root))
  end

  if !package
    extra = downloaded_watched(manifest, lock, package_name, os, cache_root, targets)
    return Found(targets: targets, watched: files(targets).concat(inputs).concat(extra), probed: probed)
  end

  names = PackageHash.native_files(workspace, root)
  hashed = !member and PackageHash.manifest_hashed?(workspace, root, names)
  if names.size == 0 and !hashed and manifest.natives.size == 0
    return Found(targets: targets, watched: [], probed: probed)
  end

  watched = [root].concat(names.map do |path: String| Paths.join(root, path) end)
  if hashed
    watched = watched.push(manifest.file)
  end

  extra = downloaded_watched(manifest, lock, package_name, os, cache_root, targets)
  Found(targets: targets, watched: watched.concat(inputs).concat(extra), probed: probed)
end

## What a Build target means once a file uses it: native/ is walked (a missing source or a link there is the packed
## failure, even for `check`), then the library the Workspace built (or found built), the name as written when the
## command does not build (`check`: the program is not run), the packed failure, or, for an optional module that could
## not be built, a library that does not open (NativeBuild.unbuilt_path).
export def build_target(workspace: Workspace.Workspace, request: Workspace.BuildRequest, name: String) -> Target
  listed = NativeBuild.listed(workspace, request)
  return Target.Unusable(listed.message) if !listed.ok?

  case workspace.native_build.call(listed.unwrap!)
    Workspace.Built.Library(path) -> Target.File(path)
    Workspace.Built.Skipped -> Target.System(name)
    Workspace.Built.Failed(packed) -> Target.Unusable(packed)
    Workspace.Built.Unbuilt(_) -> Target.File(NativeBuild.unbuilt_path(request))
  end
end

## Builds every library of the manifest that has a `build` table, for `agentica install` (a run builds while it
## links): `root` is the real folder of the project or of a package read in place. A fetched package is not built
## there: its module builds when a file first uses it, so installing it needs no compiler. The failure of the first
## build that fails is packed at the manifest and its key.
export def build_all(
  workspace: Workspace.Workspace,
  manifest: Manifest.Manifest,
  root: String,
  os: String,
  cache_root: String,
) -> Result[Void]
  for library in manifest.natives
    case library.build
      some(build) ->
        request = NativeBuild.request(library.name, build, root, os, manifest.file, cache_root, "", library.optional)
        case build_target(workspace, request, library.name)
          Target.Unusable(packed) -> return error(packed)
          _ -> next
        end

      none -> next
    end
  end

  ok()
end

# The absolute candidates of the `system` lists of this system. A list of one is not a choice, so it is not probed.
def probes(manifest: Manifest.Manifest, os: String) -> List[String]
  found: List[String] = []
  for library in manifest.natives
    for place in library.places
      if place.system == os and place.names.size > 1
        found = found.concat(place.names.filter do |name: String| Paths.rooted?(name) end)
      end
    end
  end

  found
end

# The first candidate that is an absolute path to a file that exists, else the first bare name for the loader, else the
# first candidate: an absolute path that is missing, which the VM reports when the program opens it, as it does for
# `extern "/missing.so"`.
def pick(workspace: Workspace.Workspace, names: List[String]) -> String
  for name in names
    return name if Paths.rooted?(name) and workspace.file_exists.call(name)
  end

  for name in names
    return name if !Paths.rooted?(name)
  end

  names[0]
end

# The files that the targets name.
def files(targets: Map[String, Target]) -> List[String]
  found: List[String] = []
  for name in targets.keys
    case targets[name]
      Target.File(path) -> found = found.push(path)
      Target.System(_) -> next
      Target.Build(_) -> next
      Target.Unusable(_) -> next
    end
  end

  found
end

def target_of(
  workspace: Workspace.Workspace,
  manifest: Manifest.Manifest,
  library: Manifest.NativeLibrary,
  root: String,
  os: String,
  package_name: String,
  lock: Lock.Lock,
  cache_root: String,
  buildable: Bool,
  pinned: String,
) -> Target
  if buildable and library.build.some?
    build = library.build.unwrap!
    request = NativeBuild.request(library.name, build, root, os, manifest.file, cache_root, pinned, library.optional)
    return Target.Build(request)
  end

  here = Reader.child("native", library.name)
  for place in library.places
    next if place.system != os

    if place.url != ""
      return downloaded_target(workspace, manifest, library.name, here, place, os, package_name, lock, cache_root)
    end

    return Target.System(pick(workspace, place.names)) if place.file == ""

    path = Paths.join(root, place.file)
    return Target.File(path) if workspace.file_exists.call(path)

    key = Reader.child(Reader.child(here, os), "file")
    message = "the native file #{place.file} is not in the package"
    return Target.Unusable(
      Failure.fail_key(manifest.file, key, "PKG-NATIVE-MISSING", message, Failure.hint("put the file in the package")),
    )
  end

  message = "the library #{library.name} is not declared for #{os}"
  help = "add [#{here}.#{os}] to the manifest of the package"
  Target.Unusable(Failure.fail_key(manifest.file, here, "PKG-NATIVE-PLATFORM", message, Failure.hint(help)))
end

def build?(target: Target) -> Bool
  case target
    Target.Build(_) -> true
    _ -> false
  end
end

# The files of native/ as the build walks them, which the build key covers: an edit to a source or a header it includes
# makes the bytecode cache miss, and the build runs again. A walk that fails fails the build when a file uses the
# library: none here.
def build_inputs(workspace: Workspace.Workspace, root: String) -> List[String]
  case NativeBuild.native_files(workspace, root, "", "")
    ok(paths) -> paths.map do |path: String| Paths.join(root, path) end
    error(_) -> []
  end
end

# The downloaded row on this system: the lock row it matches, verified from the cache alone. A lock the manifest
# outgrew, a row the lock lacks and a cache that cannot verify are Unusable at use, so an unused alias never fails.
def downloaded_target(
  workspace: Workspace.Workspace,
  manifest: Manifest.Manifest,
  name: String,
  here: String,
  place: Manifest.Place,
  os: String,
  package_name: String,
  lock: Lock.Lock,
  cache_root: String,
) -> Target
  row = Reader.child(here, os)
  found = Lock.find_artifact(lock, package_name, name, os)
  if !found.ok?
    message = "the lock has no native artifact for #{name} on #{os}"
    help = Failure.hint("run agentica install to lock the native artifacts the manifests declare")
    return Target.Unusable(Failure.fail_key(manifest.file, row, "PKG-LOCK-STALE", message, help))
  end

  artifact = found.unwrap!
  if artifact.url != place.url or artifact.sha256 != place.sha256 or !same_member?(artifact.member, place.member)
    message = "the lock does not list the download the manifest names for #{name} on #{os}"
    help = Failure.hint("run agentica update to lock the download the manifest names")
    return Target.Unusable(Failure.fail_key(manifest.file, row, "PKG-LOCK-STALE", message, help))
  end

  if cache_root == ""
    message = "there is no place for the native artifact cache"
    help = Failure.hint("set HOME or XDG_CACHE_HOME")
    return Target.Unusable(Failure.fail_key(manifest.file, row, "PKG-FETCH", message, help))
  end

  request = Workspace.NativeRequest(
    cache_root: cache_root,
    package: package_name,
    library: name,
    system: os,
    file: manifest.file,
    key: row,
    url: artifact.url,
    sha256: artifact.sha256,
    member: artifact.member,
  )

  case workspace.native_artifact.call(request)
    ok(path) -> Target.File(path)
    error(packed) -> Target.Unusable(packed)
  end
end

# Whether two member spellings name one member (one leading "./" is stripped at parse).
def same_member?(left: String, right: String) -> Bool
  left_canonical = NativeArtifact.canonical_member(left)
  right_canonical = NativeArtifact.canonical_member(right)
  return left == right if !left_canonical.ok? or !right_canonical.ok?

  left_canonical.unwrap! == right_canonical.unwrap!
end

# The receipt beside every downloaded payload the targets hold, so the bytecode cache watches both: a tampered
# member or receipt misses. Only File targets of downloaded rows are watched; an Unusable row opens nothing.
def downloaded_watched(
  manifest: Manifest.Manifest,
  lock: Lock.Lock,
  package_name: String,
  os: String,
  cache_root: String,
  targets: Map[String, Target],
) -> List[String]
  return [] if cache_root == ""

  found: List[String] = []
  for library in manifest.natives
    case targets.get(library.name)
      some(target) ->
        case target
          Target.File(_) ->
            artifact = Lock.find_artifact(lock, package_name, library.name, os)
            if artifact.ok?
              receipt = receipt_of(cache_root, artifact.unwrap!)
              if receipt != "" and !found.any? do |seen| seen == receipt end
                found = found.push(receipt)
              end
            end

          _ -> next
        end

      none -> next
    end
  end

  found
end

# The receipt of the cached member object, or "" when the member is not safe (validated at parse).
def receipt_of(cache_root: String, artifact: Lock.Artifact) -> String
  case NativeArtifact.canonical_member(artifact.member)
    ok(canonical) ->
      digest = NativeArtifact.member_digest_hex(canonical)
      NativeArtifact.receipt_path(cache_root, artifact.sha256, digest)
    error(_) -> ""
  end
end
