## The project of a build (docs/grammar/05b-modules.md): the manifest agentica.toml that is nearest to
## the root file, going up from its folder, the lock beside it and the workspace the project is in, if any. A build
## with no manifest is as before. A manifest that declares dependencies needs a lock that has every one of them, from
## the same source and with the same pin: that is checked here, once, before any file is loaded, and the build never
## writes the lock. The manifest of each locked package that is in deps/ (or in a workspace member's folder) is
## checked against the lock just after, also before any file is loaded (package_import.agc, check_manifests).

import Paths from "../modules/import_path"
import Failure from "../modules/link_failure"
import Workspace from "../modules/workspace"
import GitSource from "git_source"
import Lock from "lock"
import Manifest from "manifest"
import Members from "members"

# The names of the two files, beside each other in the folder of the project.
MANIFEST_FILE = "agentica.toml"
LOCK_FILE = "agentica.lock"

## A manifest, the folder that holds it, the lock that goes with it (empty when the manifest declares no dependency)
## and the workspace of the project (members.agc; none when the project is in no workspace).
export struct Found
  dir: String
  manifest: Manifest.Manifest
  lock: Lock.Lock
  members: Members.Members
end

## No manifest above the root file, or one.
export enum Project
  Bare
  Declared(Found)
end

## Finds the project of a root file in the folder root_dir (a canonical path). A failure is a packed failure:
## PKG-MANIFEST-INVALID, PKG-LOCK-MISSING, PKG-LOCK-INVALID or PKG-LOCK-STALE.
export def find(workspace: Workspace.Workspace, root_dir: String) -> Result[Project]
  dir = nearest(workspace, root_dir)
  if dir == ""
    return ok(Project.Bare)
  end

  manifest = try Manifest.read(workspace, Paths.join(dir, MANIFEST_FILE))
  members = try Members.find(workspace, dir)
  empty = Lock.Lock(file: Paths.join(dir, LOCK_FILE), packages: [], artifacts: [])
  if manifest.dependencies.size == 0 and !Manifest.has_downloaded(manifest)
    return ok(Project.Declared(Found(dir: dir, manifest: manifest, lock: empty, members: members)))
  end

  if !workspace.file_exists.call(empty.file)
    if manifest.dependencies.size == 0
      return error(
        Failure.fail_file(
          empty.file,
          "PKG-LOCK-MISSING",
          "#{MANIFEST_FILE} declares native downloads but there is no #{LOCK_FILE}",
          Failure.hint("run agentica install to lock the native artifacts the manifest declares"),
        ),
      )
    end

    return error(
      Failure.fail_file(
        empty.file,
        "PKG-LOCK-MISSING",
        "#{MANIFEST_FILE} declares dependencies but there is no #{LOCK_FILE}",
        Failure.hint("write #{LOCK_FILE} beside #{MANIFEST_FILE}, with an entry for each dependency"),
      ),
    )
  end

  lock = try Lock.read(workspace, empty.file)
  try check_dependencies(lock, manifest, members, false)
  return ok(Project.Declared(Found(dir: dir, manifest: manifest, lock: lock, members: members)))
end

## Finds the project of the commands that write the lock (`add`, `update`). The manifest is read as `find` reads it,
## but the lock is not checked against it: those commands are what makes a missing, stale or partial lock right. A lock
## that is there must be a good one (PKG-LOCK-INVALID); a lock that is not there is an empty one.
export def find_to_write(workspace: Workspace.Workspace, root_dir: String) -> Result[Project]
  dir = nearest(workspace, root_dir)
  if dir == ""
    return ok(Project.Bare)
  end

  manifest = try Manifest.read(workspace, Paths.join(dir, MANIFEST_FILE))
  members = try Members.find(workspace, dir)
  lock = Lock.Lock(file: Paths.join(dir, LOCK_FILE), packages: [], artifacts: [])
  if workspace.file_exists.call(lock.file)
    lock = try Lock.read(workspace, lock.file)
  end

  return ok(Project.Declared(Found(dir: dir, manifest: manifest, lock: lock, members: members)))
end

## The local names of the dependencies of the root project, in the order of the manifest.
export def direct_names(project: Project) -> List[String]
  case project
    Project.Bare -> return []
    Project.Declared(found) -> return Manifest.names(found.manifest)
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

## Checks the dependencies of a manifest against the lock: each must be in the lock, with the same source and pin. A
## missing one is PKG-LOCK-STALE. One with another source is PKG-LOCK-STALE for the manifest of the project (the lock
## is out of date) and PKG-SOURCE-CONFLICT for the manifest of a package, `of_package` (one name cannot stand for two
## sources in one build). A dependency that is a member of the workspace `members` must be locked as a member, and any
## other as a fetched package: the same two codes. The failure names the manifest and `dependencies.<name>`.
export def check_dependencies(
  lock: Lock.Lock,
  manifest: Manifest.Manifest,
  members: Members.Members,
  of_package: Bool,
) -> Result[Void]
  for dependency in manifest.dependencies
    path = "dependencies.#{dependency.name}"
    found = Lock.find(lock, dependency.name)
    if !found.ok?
      return error(stale(manifest.file, path, "#{dependency.name} is not in #{LOCK_FILE}"))
    end

    locked = found.unwrap!
    if !GitSource.same?(dependency.source, locked.source)
      wanted = GitSource.describe(dependency.source)
      message = "#{dependency.name} is #{wanted}, but #{LOCK_FILE} has #{GitSource.describe(locked.source)}"
      if of_package
        return error(conflict(manifest.file, path, message))
      end

      return error(stale(manifest.file, path, message))
    end

    if Members.member?(members, dependency.source) != locked.member
      message = "#{dependency.name} is a workspace member, but #{LOCK_FILE} has it fetched"
      if locked.member
        message = "#{dependency.name} is not a workspace member of this project, but #{LOCK_FILE} has it as one"
      end

      if of_package
        return error(conflict(manifest.file, path, message))
      end

      return error(stale(manifest.file, path, message))
    end
  end

  return ok()
end

## Whether the file `key` (a canonical path) follows the style keys of the manifest in `style_dir` ("" when no manifest
## asks for a style rule): it is below that folder, no folder between them has an agentica.toml (that is another
## project, whose own keys are not read) and it is not in the agc_libs/ of the folder, which holds libraries.
export def styled?(workspace: Workspace.Workspace, style_dir: String, key: String) -> Bool
  if style_dir == "" or !Paths.inside?(style_dir, key) or Paths.inside?(Paths.join(style_dir, "agc_libs"), key)
    return false
  end

  here = Paths.directory_of(key)
  while here != style_dir and Paths.inside?(style_dir, here)
    if workspace.file_exists.call(Paths.join(here, MANIFEST_FILE))
      return false
    end

    here = Paths.directory_of(here)
  end

  return true
end

# The folder with an agentica.toml that is the nearest to dir, going up; "" when there is none.
def nearest(workspace: Workspace.Workspace, dir: String) -> String
  here = dir
  while here != ""
    if workspace.file_exists.call(Paths.join(here, MANIFEST_FILE))
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

def stale(file: String, path: String, message: String) -> String
  help = Failure.hint("make #{LOCK_FILE} list the source and the pin that the manifest names")
  return Failure.fail_key(file, path, "PKG-LOCK-STALE", message, help)
end

def conflict(file: String, path: String, message: String) -> String
  return Failure.fail_key(
    file,
    path,
    "PKG-SOURCE-CONFLICT",
    message,
    Failure.hint("one name stands for one source in a build: make the manifests agree"),
  )
end
