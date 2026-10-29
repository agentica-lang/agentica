## The files that the caches of the front end keep in `_build/` (the bytecode cache of `agentica FILE.agc`,
## io/bytecode_cache.agc, and the check cache, io/check_cache.agc): where the folder is, what an entry must match
## besides its own inputs, and the checks that make a folder and a file safe to trust. A cache entry is used only when
## it is what this program made, and any doubt is a miss (the rules are in the module doc of bytecode_cache.agc). This
## is front-end I/O, so the --deny-* flags (which are for the program) do not reach it.

import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Workspace from "../modules/workspace"
import Members from "../packages/members"
import Project from "../packages/project"
import RandomName from "random_name"

# The folder of the project (or of the root file) that holds the build outputs, and the variable that names another
# folder in place of the first.
BUILD_FOLDER = "_build"
BUILD_VARIABLE = "AGENTICA_BUILD_DIR"

# The deadline of each system call, in milliseconds, and the most one File.read_bytes gives.
export IO_TIMEOUT_MS = 10_000
export PIECE = 1_048_576

# The files that decide which package or library an import reads, next to the manifest.
MANIFEST_FILE = "agentica.toml"
PROJECT_FILES = [MANIFEST_FILE, "agentica.lock"]

# The write bits of the group and of others (020 and 002).
GROUP_OTHER_WRITE = 18

# A file that a run could not finish is left with this in its name; the next one to write removes the old ones.
export TEMP_MARK = ".agcb.tmp-"
STALE_TEMP_SECONDS = 3600

# How often, and how far apart, discard tries on Windows to remove a temporary file that cannot be removed yet.
DISCARD_TRIES = 5
DISCARD_PAUSE_MS = 30

## Where the caches of a root file are kept and what their entries must match. `build` is the `_build/` folder and
## `beside` is true for the `_build/` of the project, false for the folder of AGENTICA_BUILD_DIR. `libs_dir` is the
## folder whose agc_libs/ the build reads first. `binary` and `inputs` are lines of the key of an entry: the size, time
## and path of the running binary, and a digest of what, besides the files an import reads, changes what a build makes
## of the root.
export struct Site
  build: String
  beside: Bool
  libs_dir: String
  binary: String
  inputs: String
end

## The site of the caches for the real path `real` of a root file. The inputs are read now, before the work, so a file
## that changes while the front end works makes the next lookup miss instead of keeping the old result under the new
## key.
export def site(settings: Env.Settings, real: String) -> Result[Site]
  build = try File.stat(settings.self_path, IO_TIMEOUT_MS)
  root_dir = Paths.directory_of(real)
  project = try Project.find(settings.workspace, root_dir)
  inputs = try inputs_digest(settings, project)
  libs_dir = Project.library_dir(project, root_dir)
  override = System.env(BUILD_VARIABLE)
  build_dir = Paths.join(libs_dir, BUILD_FOLDER)
  beside = true
  if override.ok? and override.unwrap! != ""
    build_dir = override.unwrap!
    beside = false
  end

  return ok(
    Site(
      build: build_dir,
      beside: beside,
      libs_dir: libs_dir,
      binary: "build #{build.size_bytes}-#{build.modified_seconds} #{settings.self_path}",
      inputs: "inputs #{inputs}",
    ),
  )
end

# The folder or the file at `path` must be of this `kind` as it stands (File.lstat: a link is its own kind and is
# refused) and, where the system has owners and modes (`user` is not -1), be owned by the user of this process and
# writable by no one else. On Windows any real folder and file pass: the cache trusts its folder, with no owner or ACL
# check, and a folder that other users can write is out of scope.
export def private_kind(path: String, kind: String, user: Int) -> Result[Void]
  info = try File.lstat(path, IO_TIMEOUT_MS)
  if info.kind != kind
    return error("#{path} is not a #{kind}")
  end

  if user >= 0 and (info.user_id != user or info.mode.bit_and(GROUP_OTHER_WRITE) != 0)
    return error("#{path} is not private to this user")
  end

  return ok()
end

# The user id of this process, which no builtin gives: the owner of a file made now with `create_private`, in the first
# temporary folder that takes one. The name is random and the file is new and not followed, so a planted name or link
# cannot give another id; a temporary folder that others can write without the sticky bit could still swap the file
# between the create and the stat, which is a setting of the user's. -1 on Windows, where `user_id` is always 0 and
# means nothing.
export def own_user() -> Result[Int]
  if System.os() == "windows"
    return ok(-1)
  end

  name = try RandomName.hex()
  places = ["/var/tmp", "/tmp"]
  from_environment = System.env("TMPDIR")
  if from_environment.ok? and from_environment.unwrap! != ""
    places = [from_environment.unwrap!].concat(places)
  end

  for place in places
    made_at = Paths.join(place, "agentica-id-#{name}")
    made = File.open(made_at, "create_private", IO_TIMEOUT_MS)
    if made.ok?
      File.close(made.unwrap!, IO_TIMEOUT_MS)
      info = File.lstat(made_at, IO_TIMEOUT_MS)
      Path.remove(made_at, IO_TIMEOUT_MS)
      if info.ok?
        return ok(info.unwrap!.user_id)
      end
    end
  end

  return error("cannot find out the user of this process")
end

# A folder that exists must pass private_kind; one that does not is made with `Dir.mkdir_private`, one level only (the
# folders above it are made with the default mode when they are missing). True when it was made now.
export def private_folder(path: String, user: Int) -> Result[Bool]
  if File.lstat(path, IO_TIMEOUT_MS).ok?
    try private_kind(path, "directory", user)
    return ok(false)
  end

  above = Paths.directory_of(path)
  if above != ""
    Dir.mkdir(above, IO_TIMEOUT_MS)
  end

  try Dir.mkdir_private(path, IO_TIMEOUT_MS)
  return ok(true)
end

# A new file that only this user can use. `create_private` fails on a name that exists and never follows a link.
export def write_private(path: String, data: Bytes) -> Result[Void]
  out = try File.open(path, "create_private", IO_TIMEOUT_MS)
  rest = data
  while rest.size > 0
    written = File.write_bytes(out, rest.take(PIECE), IO_TIMEOUT_MS)
    if !written.ok?
      File.close(out, IO_TIMEOUT_MS)
      return written
    end

    rest = rest.drop(PIECE)
  end

  return File.close(out, IO_TIMEOUT_MS)
end

# Puts `data` at `target` through the new private file `temporary` (beside the target, named with TEMP_MARK). A rename
# never replaces (Path.rename), so the old entry is removed first: a reader that comes in between finds none, which is
# a miss, and a run that dies in between leaves no entry. False when anything fails, and then `temporary` is removed:
# a run that lost the race to another one (its rename finds the entry the other made) must not leave its file. The
# write handle is closed by then (write_private closes it on every path).
export def install(temporary: String, data: Bytes, target: String) -> Bool
  if !write_private(temporary, data).ok?
    discard(temporary)
    return false
  end

  remove_file(target)
  if !Path.rename(temporary, target, IO_TIMEOUT_MS).ok?
    discard(temporary)
    return false
  end

  return true
end

# Removes a temporary file of this run. Only this run opens it, but on Windows a scanner (an antivirus or an indexer)
# can hold a file just written or renamed for a moment, and the removal then fails with a sharing violation; there it
# is tried again a few times. Elsewhere it is tried once: a failure there is permanent. A scanner that shares the file
# for deletion lets the removal succeed and keeps the name in the folder until it lets go, which no retry shortens.
# A file that cannot be removed is left for the sweep.
export def discard(path: String) -> Void
  tries = 1
  if System.os() == "windows"
    tries = DISCARD_TRIES
  end

  for attempt in 0...tries
    if Path.remove(path, IO_TIMEOUT_MS).ok?
      return
    end

    if attempt + 1 < tries
      Task.sleep(DISCARD_PAUSE_MS)
    end
  end
end

# Removes the file or the link at `path` (a link is removed as a link, never followed). A folder in its place stays
# (the rename then fails and the entry is not written): `Path.remove` would delete the whole folder.
export def remove_file(path: String) -> Void
  info = File.lstat(path, IO_TIMEOUT_MS)
  if info.ok? and (info.unwrap!.kind == "file" or info.unwrap!.kind == "link")
    Path.remove(path, IO_TIMEOUT_MS)
  end
end

# Removes the temporary files that a run left (it died between the write and the rename) once they are an hour old.
export def sweep(folder: String) -> Void
  names = Dir.list(folder, IO_TIMEOUT_MS)
  if !names.ok?
    return
  end

  now = Time.now_ms() / 1000
  for name in names.unwrap!
    if name.contains?(TEMP_MARK)
      path = Paths.join(folder, name)
      info = File.lstat(path, IO_TIMEOUT_MS)
      if info.ok? and info.unwrap!.kind == "file" and now - info.unwrap!.modified_seconds > STALE_TEMP_SECONDS
        Path.remove(path, IO_TIMEOUT_MS)
      end
    end
  end
end

export def digest(data: Bytes) -> String
  return Digest.sha256_hexdigest(data)
end

# What, besides the files an import reads, changes what a build makes of the root: the environment that places
# libraries and packages, and the project (the manifest the build finds and its lock).
def inputs_digest(settings: Env.Settings, project: Project.Project) -> Result[String]
  workspace = settings.workspace
  env = settings.env
  parts = ["env #{env.agentica_path}|#{env.xdg_data_home}|#{env.xdg_cache_home}|#{env.home}|#{env.local_app_data}"]
  case project
    Project.Project.Bare -> parts = parts.push("project -")
    Project.Project.Declared(manifest) ->
      parts = parts.push("project #{manifest.dir}")
      for name in PROJECT_FILES
        parts = parts.push("#{name} #{file_digest(workspace, Paths.join(manifest.dir, name))}")
      end

      parts = parts.concat(workspace_parts(workspace, manifest))
  end

  return ok(digest(parts.join("\n").bytes))
end

# The workspace of the project (packages/members.agc): the manifest that holds the table, and the manifest of each
# member the lock names, which decide the packages a build reads from the members' folders. The .agc files of a member
# are sources of the entry like any other.
def workspace_parts(workspace: Workspace.Workspace, found: Project.Found) -> List[String]
  if found.members.root == ""
    return []
  end

  parts = ["workspace #{found.members.root} #{file_digest(workspace, Paths.join(found.members.root, MANIFEST_FILE))}"]
  for locked in found.lock.packages
    if locked.member
      folder = Members.folder_of(found.members, locked.source)
      parts = parts.push("member #{folder} #{file_digest(workspace, Paths.join(folder, MANIFEST_FILE))}")
    end
  end

  return parts
end

# "-" for a file that is not there.
def file_digest(workspace: Workspace.Workspace, path: String) -> String
  read = workspace.read_bytes.call(path)
  if !read.ok?
    return "-"
  end

  return digest(read.unwrap!)
end
