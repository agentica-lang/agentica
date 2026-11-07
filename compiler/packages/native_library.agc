## The native libraries of a package (docs/grammar/05b-modules.md): `[native.NAME]` in its manifest says where the
## library that `extern "NAME"` means is on each system, either a file in the package's native/ folder (hashed with the
## package, so the lock covers it) or a name for the system loader. A file is turned into its absolute path, which the
## VM opens as it opens any absolute library; never a search. A `system` entry lists one or more candidates: the first
## absolute path that exists is chosen, else the first bare name, so a library the loader cannot find by name (a
## Homebrew one on macOS) is found by its path. The choice is made here, from the machine, and never written to the
## manifest or the lock, which stay the same on every machine. Only the entry of this system is looked at, and only
## when a file of the package uses the library, so a package works on the systems it names and is refused on the
## others where it is used. A package read in place (the project, a workspace member, a `path` dependency) with a
## `build` table builds the library from its C sources instead (native_build.agc), whatever its system entries say; a
## fetched package never builds. This does no I/O of its own: it asks the Workspace.

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
## system loader, or the packed failure to report when the file uses it.
export enum Target
  File(String)
  System(String)
  Unusable(String)
end

## What a manifest's [native] table means on one system: the target of each library it declares, what the bytecode
## cache must watch because the program opens it, and the absolute candidates of a `system` list (probed), whose
## presence the choice depended on: the cache notes whether each exists, not what it holds. watched, for a package, is
## the folder itself (the cache digests the names of its native/ files, so an added file is seen), every file of
## native/ (a library may load others), the manifest when the package hash covers it, and each built library. For the
## project it is the declared files for this system (a built library among them) and, when it builds one, the files of
## its native/ folder: its manifest is in the cache key already, and its folder is not walked. watched is empty when
## there is nothing to open.
export struct Found
  targets: Map[String, Target]
  watched: List[String]
  probed: List[String]
end

## The libraries a manifest declares, for the system `os` ("linux", "macos" or "windows"). `root` is the real folder of
## the package (or of the project), which holds the files. `package` is false for the project, whose files are not
## hashed; `member` is true for a workspace member or a `path` dependency, whose are not either: those and the project
## are read in place, so they build what has a `build` table. `package_name` is the lock key of the
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
  package_name: String,
  lock: Lock.Lock,
  cache_root: String,
) -> Found
  buildable = !package or member
  targets: Map[String, Target] = {}
  for library in manifest.natives
    target = target_of(workspace, manifest, library, root, os, package_name, lock, cache_root, buildable)
    targets = targets.put(library.name, target)
  end

  probed = probes(manifest, os)
  built = built_files(manifest, targets, buildable)
  if !package
    extra = downloaded_watched(manifest, lock, package_name, os, cache_root, targets)
    inputs: List[String] = []
    if built.size > 0
      inputs = build_inputs(workspace, root)
    end

    return Found(targets: targets, watched: files(targets).concat(inputs).concat(extra), probed: probed)
  end

  names = PackageHash.native_files(workspace, root)
  hashed = !member and PackageHash.manifest_hashed?(workspace, root, names)
  if names.size == 0 and !hashed and manifest.natives.size == 0
    return Found(targets: targets, watched: [], probed: probed)
  end

  watched = [root].concat(names.map do |path: String| Paths.join(root, path) end).concat(built)
  if hashed
    watched = watched.push(manifest.file)
  end

  extra = downloaded_watched(manifest, lock, package_name, os, cache_root, targets)
  return Found(targets: targets, watched: watched.concat(extra), probed: probed)
end

## Builds every library of the manifest that has a `build` table, for `agentica install` (a run builds while it
## links): `root` is the real folder of the project or of a package read in place. The failure of the first build that
## fails is packed at the manifest and its key.
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
        case built_target(workspace, manifest, library.name, build, root, os, cache_root)
          Target.Unusable(packed) -> return error(packed)
          _ -> next
        end

      none -> next
    end
  end

  return ok()
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

  return found
end

# The first candidate that is an absolute path to a file that exists, else the first bare name for the loader, else the
# first candidate: an absolute path that is missing, which the VM reports when the program opens it, as it does for
# `extern "/missing.so"`.
def pick(workspace: Workspace.Workspace, names: List[String]) -> String
  for name in names
    if Paths.rooted?(name) and workspace.file_exists.call(name)
      return name
    end
  end

  for name in names
    if !Paths.rooted?(name)
      return name
    end
  end

  return names[0]
end

# The files that the targets name.
def files(targets: Map[String, Target]) -> List[String]
  found: List[String] = []
  for name in targets.keys
    case targets[name]
      Target.File(path) -> found = found.push(path)
      Target.System(_) -> next
      Target.Unusable(_) -> next
    end
  end

  return found
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
) -> Target
  if buildable and library.build.some?
    return built_target(workspace, manifest, library.name, library.build.unwrap!, root, os, cache_root)
  end

  here = Reader.child("native", library.name)
  for place in library.places
    if place.system != os
      next
    end

    if place.url != ""
      return downloaded_target(workspace, manifest, library.name, here, place, os, package_name, lock, cache_root)
    end

    if place.file == ""
      return Target.System(pick(workspace, place.names))
    end

    path = Paths.join(root, place.file)
    if workspace.file_exists.call(path)
      return Target.File(path)
    end

    key = Reader.child(Reader.child(here, os), "file")
    message = "the native file #{place.file} is not in the package"
    return Target.Unusable(
      Failure.fail_key(manifest.file, key, "PKG-NATIVE-MISSING", message, Failure.hint("put the file in the package")),
    )
  end

  message = "the library #{library.name} is not declared for #{os}"
  help = "add [#{here}.#{os}] to the manifest of the package"
  return Target.Unusable(Failure.fail_key(manifest.file, here, "PKG-NATIVE-PLATFORM", message, Failure.hint(help)))
end

# The library built from the `build` table: the path the machine built (or found built) it at. A command that does
# not build (`check`) gets the name for the loader, which it never opens.
def built_target(
  workspace: Workspace.Workspace,
  manifest: Manifest.Manifest,
  name: String,
  build: NativeBuild.Build,
  root: String,
  os: String,
  cache_root: String,
) -> Target
  case NativeBuild.request(workspace, name, build, root, os, manifest.file, cache_root)
    error(packed) -> return Target.Unusable(packed)
    ok(request) ->
      case workspace.native_build.call(request)
        Workspace.Built.Library(path) -> return Target.File(path)
        Workspace.Built.Skipped -> return Target.System(name)
        Workspace.Built.Failed(packed) -> return Target.Unusable(packed)
      end
  end
end

# The libraries that were built here: their files, which the bytecode cache watches, so a removed build misses.
def built_files(manifest: Manifest.Manifest, targets: Map[String, Target], buildable: Bool) -> List[String]
  found: List[String] = []
  if !buildable
    return found
  end

  for library in manifest.natives
    if library.build.some?
      case targets.get(library.name)
        some(target) ->
          case target
            Target.File(path) -> found = found.push(path)
            _ -> next
          end

        none -> next
      end
    end
  end

  return found
end

# The files of the project's native/ folder, which a build key covers: an edit to a source or a header it includes
# makes the bytecode cache miss, and the build runs again. A walk that fails failed the build already: none here.
def build_inputs(workspace: Workspace.Workspace, root: String) -> List[String]
  case NativeBuild.native_files(workspace, root, "", "")
    ok(paths) -> return paths.map do |path: String| Paths.join(root, path) end
    error(_) -> return []
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
    ok(path) -> return Target.File(path)
    error(packed) -> return Target.Unusable(packed)
  end
end

# Whether two member spellings name one member (one leading "./" is stripped at parse).
def same_member?(left: String, right: String) -> Bool
  left_canonical = NativeArtifact.canonical_member(left)
  right_canonical = NativeArtifact.canonical_member(right)
  if !left_canonical.ok? or !right_canonical.ok?
    return left == right
  end

  return left_canonical.unwrap! == right_canonical.unwrap!
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
  if cache_root == ""
    return []
  end

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

  return found
end

# The receipt of the cached member object, or "" when the member is not safe (validated at parse).
def receipt_of(cache_root: String, artifact: Lock.Artifact) -> String
  case NativeArtifact.canonical_member(artifact.member)
    ok(canonical) ->
      digest = NativeArtifact.member_digest_hex(canonical)
      return NativeArtifact.receipt_path(cache_root, artifact.sha256, digest)
    error(_) -> return ""
  end
end
