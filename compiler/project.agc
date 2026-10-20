## The project of a build (docs/future/45-packages.md, 45.5 and 45.6): the manifest agentica.toml that is nearest to
## the root file, going up from its folder, and the lock beside it. A build with no manifest is as before. A manifest
## that declares dependencies needs a lock that agrees with it, over the whole graph: that is checked here, once,
## before any file is loaded, and the build never writes the lock.

import Diag from "diagnostic"
import Probe from "file_probe"
import Paths from "import_path"
import Failure from "link_failure"
import Lock from "lock"
import Manifest from "manifest"
import Semver from "semver"

# The names of the two files, beside each other in the folder of the project.
MANIFEST_FILE = "agentica.toml"
LOCK_FILE = "agentica.lock"

## A manifest, the folder that holds it and the lock that goes with it (empty when the manifest declares no
## dependency).
export struct Found
  dir: String
  manifest: Manifest.Manifest
  lock: Lock.Lock
end

## No manifest above the root file, or one.
export enum Project
  Bare
  Declared(Found)
end

## Finds the project of a root file in the folder root_dir (a canonical path). A failure is a packed failure:
## PKG-MANIFEST- INVALID, PKG-LOCK-MISSING, PKG-LOCK-INVALID, PKG-LOCK-STALE or PKG-MAJOR-CONFLICT.
export def find(root_dir: String) -> Result[Project]
  dir = nearest(root_dir)
  if dir == ""
    return ok(Project.Bare)
  end
  manifest = try Manifest.read(Paths.join(dir, MANIFEST_FILE))
  empty = Lock.Lock(file: Paths.join(dir, LOCK_FILE), packages: [])
  if manifest.dependencies.size == 0
    return ok(Project.Declared(Found(dir: dir, manifest: manifest, lock: empty)))
  end
  if !Probe.file?(empty.file)
    return error(
      Failure.fail_key(
        empty.file,
        "",
        "PKG-LOCK-MISSING",
        "#{MANIFEST_FILE} declares dependencies but there is no #{LOCK_FILE}",
        Failure.hint("the lock is written by agentica add and agentica update"),
      ),
    )
  end
  lock = try Lock.read(empty.file)
  try check_graph(manifest, lock)
  return ok(Project.Declared(Found(dir: dir, manifest: manifest, lock: lock)))
end

## The keys of the direct dependencies of the root project, in the order of the manifest.
export def direct_keys(project: Project) -> List[String]
  case project
    Project.Bare -> return []
    Project.Declared(found) -> return found.manifest.dependencies.map do |dependency| dependency.key end
  end
end

## The folder whose agc_libs/ the pkg/ search reads first: the folder of the manifest when there is one, else the
## folder of the root file.
export def library_dir(project: Project, root_dir: String) -> String
  case project
    Project.Bare -> return root_dir
    Project.Declared(found) -> return found.dir
  end
end

# The folder with an agentica.toml that is the nearest to dir, going up; "" when there is none.
def nearest(dir: String) -> String
  here = dir
  while here != ""
    if Probe.file?(Paths.join(here, MANIFEST_FILE))
      return here
    end
    parent = Paths.directory_of(here)
    if parent == here
      return ""
    end
    here = parent
  end
  return ""
end

# Every minimum that a dependent asks for must be met by the locked version: the manifest asks for its direct
# dependencies, and each locked package for its own. The check covers the whole lock, not only what the root reaches.
def check_graph(manifest: Manifest.Manifest, lock: Lock.Lock) -> Result[Void]
  for dependency in manifest.dependencies
    path = "dependencies.#{dependency.key}"
    try need(lock, manifest.file, path, dependency.key, dependency.minimum)
  end
  for index in 0...lock.packages.size
    locked = lock.packages[index]
    for position in 0...locked.requires.size
      required = locked.requires[position]
      path = "package[#{index}].requires[#{position}]"
      try need(lock, lock.file, path, required.key, required.minimum)
    end
  end
  return ok()
end

# One dependent (file and path name it) asks for key at minimum. Parsing cannot fail: both files were validated.
def need(lock: Lock.Lock, file: String, path: String, key: String, minimum: String) -> Result[Void]
  found = Lock.find(lock, key)
  if !found.ok?
    return error(stale(file, path, "#{key} is not in #{LOCK_FILE}"))
  end
  locked = Semver.parse(found.unwrap!.version).unwrap!
  wanted = Semver.parse(minimum).unwrap!
  if locked.major != wanted.major
    message = "#{key} is locked at version #{found.unwrap!.version}, but major #{wanted.major} is asked for"
    return error(
      Failure.fail_key(
        file,
        path,
        "PKG-MAJOR-CONFLICT",
        message,
        Failure.hint("a new major version is a new repository, with its own key"),
      ),
    )
  elsif Semver.compare(locked, wanted) < 0
    below = "#{key} is locked at version #{found.unwrap!.version}, below the minimum #{minimum}"
    return error(stale(file, path, below))
  end
  return ok()
end

def stale(file: String, path: String, message: String) -> String
  return Failure.fail_key(file, path, "PKG-LOCK-STALE", message, Failure.hint("agentica update rewrites the lock"))
end
