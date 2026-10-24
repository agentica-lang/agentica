## `agentica install`: fills the package cache from agentica.lock and writes every locked package into `deps/<name>/`
## beside agentica.toml (docs/grammar/05b-modules.md). The project is the one of the working folder, found as a build
## finds it (the nearest agentica.toml going up), and the lock is read as a build reads it, so a manifest that asks for
## more than the lock holds is PKG-LOCK-STALE. The lock is never written. A package that is in the cache with the
## locked hash is left alone and git does not run for it; the others are fetched (io/package_fetch.agc), one after the
## other, and the first failure stops the command. When all are in the cache, the manifest of each package is checked
## against the lock, as a build checks it, and only then are the files written to deps/ (io/package_deps.agc), so a
## cache or a manifest that fails those checks writes nothing there. A folder of deps/ that the lock does not name is
## left as it is. A package the lock marks as a member of the workspace of the project is neither fetched nor written
## to deps/: the build reads it from the member's folder, and its manifest is checked there.

import NativeArtifact from "../packages/native_artifact"
import Engine from "../io/native_artifact"
import PackageDeps from "../io/package_deps"
import PackageFetch from "../io/package_fetch"
import Env from "../modules/link_env"
import Lock from "../packages/lock"
import PackageCache from "../packages/package_cache"
import PackageImport from "../packages/package_import"
import Project from "../packages/project"
import Reader from "../packages/toml_read"
import CliProject from "cli_project"
import Reply from "cli_reply"

# The deadline of one downloaded artifact during install (the engine caps hops and bytes).
NATIVE_TIMEOUT_MS = 300_000

## Runs `install` in the working folder. `style` is the output style of the options: with `json` a success prints
## `{"ok":true}`, as `check` does.
export def run(settings: Env.Settings, style: String) -> Reply.Answer
  return CliProject.run(style, settings.workspace) do |dir: String| install(settings, dir) end
end

## Fills the cache with every package of the lock, in the order of the file, then every downloaded native artifact
## of this host. The lines say `fetched` or `in the cache` for each package; artifacts print nothing: they are pinned
## for all systems in the lock, and only this host is fetched. A lock with neither stays quiet.
export def fill_all(settings: Env.Settings, lock: Lock.Lock) -> Result[String]
  if lock.packages.size == 0 and lock.artifacts.size == 0
    return ok("nothing to install\n")
  end
  lines: List[String] = []
  if lock.packages.size > 0
    cache = try PackageFetch.cache_for(settings.env, lock.file, lock.packages)
    for index in 0...lock.packages.size
      locked = lock.packages[index]
      label = Lock.label(locked)
      if locked.member
        lines = lines.push("in the workspace #{label}")
        next
      end
      place = PackageFetch.Place(file: lock.file, entry: Reader.item("package", index))
      filled = try PackageFetch.fill(settings.workspace, cache, place, locked)
      case filled
        PackageFetch.Filled.Fetched -> lines = lines.push("fetched #{label}")
        PackageFetch.Filled.Present -> lines = lines.push("in the cache #{label}")
      end
    end
  end
  try fill_artifacts(settings, lock)
  if lines.size == 0
    return ok("nothing to install\n")
  end
  return ok("#{lines.join("\n")}\n")
end

# The downloaded native artifacts of this host in the lock, verified from the cache alone afterwards: the archive is
# downloaded and hashed once per SHA-256, then the member is extracted into its own object. Other systems stay pinned
# but unfetched. A corrupt cache is a packed failure at the lock entry.
def fill_artifacts(settings: Env.Settings, lock: Lock.Lock) -> Result[Void]
  wanted = lock.artifacts.filter do |artifact: Lock.Artifact| artifact.system == settings.env.os end
  if wanted.size == 0
    return ok()
  end
  cache = PackageCache.root(settings.env)
  if cache == ""
    message = "there is no package cache folder: HOME is not set"
    place = PackageFetch.Place(file: lock.file, entry: "native-artifact")
    return error(PackageFetch.fail(place, "PKG-FETCH", "", message, "set HOME or XDG_CACHE_HOME"))
  end
  for artifact in wanted
    source = NativeArtifact.Source(url: artifact.url, sha256: artifact.sha256, member: artifact.member)
    context = NativeArtifact.Context(file: lock.file, key: artifact_key(lock, artifact))
    case Engine.fetch(cache, source, context, NATIVE_TIMEOUT_MS)
      ok(_) -> next
      error(packed) -> return error(packed)
    end
  end
  return ok()
end

# The `native-artifact[i]` key path of this artifact in its lock, for precise failures.
def artifact_key(lock: Lock.Lock, artifact: Lock.Artifact) -> String
  for index in 0...lock.artifacts.size
    here = lock.artifacts[index]
    if here.package == artifact.package and here.library == artifact.library and here.system == artifact.system
      return Reader.item("native-artifact", index)
    end
  end
  return "native-artifact"
end

# The lines of the answer, or a packed failure.
def install(settings: Env.Settings, dir: String) -> Result[String]
  workspace = settings.workspace
  project = try Project.find(workspace, dir)
  case project
    Project.Project.Bare -> return error(CliProject.missing_manifest(dir))
    Project.Project.Declared(found) ->
      lines = try fill_all(settings, found.lock)
      scope = PackageImport.scope_of(project)
      try check_cache(settings, found.lock, scope)
      try PackageDeps.sync(settings, found.lock.file, scope.deps, found.lock.packages, [])
      return ok(lines)
  end
end

# The manifests of the packages in the cache, checked against the lock before anything is written to deps/.
def check_cache(settings: Env.Settings, lock: Lock.Lock, scope: PackageImport.Scope) -> Result[Void]
  if lock.packages.size == 0
    return ok()
  end
  cache = try PackageFetch.cache_for(settings.env, lock.file, lock.packages)
  folders: Map[String, String] = {}
  for locked in lock.packages
    if locked.member
      folders = folders.put(locked.name, PackageImport.folder_of(scope, locked))
    else
      folders = folders.put(locked.name, PackageCache.folder(cache, locked.source, locked.commit))
    end
  end
  try PackageImport.check_folders(settings.workspace, scope, folders)
  return ok()
end
