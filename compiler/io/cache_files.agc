## The files that the caches of the front end keep in `_build/` (the bytecode cache of `agentica FILE.agc`,
## io/bytecode_cache.agc, and the check cache, io/check_cache.agc): where the folder is, what an entry must match
## besides its own inputs, and the checks that make a folder and a file safe to trust. A cache entry is used only when
## it is what this program made, and any doubt is a miss (the rules are in the module doc of bytecode_cache.agc). This
## is front-end I/O, so the --deny-* flags (which are for the program) do not reach it.

import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Workspace from "../modules/workspace"
import Lock from "../packages/lock"
import Project from "../packages/project"
import RandomName from "random_name"

# The deadline of each system call, in milliseconds, and the most one File.read_bytes gives.
IO_TIMEOUT_MS = 10_000
PIECE = 1_048_576

# A file that a run could not finish is left with this in its name; the next one to write removes the old ones.
TEMP_MARK = ".agcb.tmp-"

## Where the caches of a root file are kept and what their entries must match. `build` is the `_build/` folder and
## `beside` is true for the `_build/` of the project, false for the folder of AGENTICA_BUILD_DIR. `libs_dir` is the
## folder whose agc_libs/ the build reads first. `binary` and `inputs` are lines of the key of an entry: the size, time
## and path of the running binary, and a digest of what, besides the files an import reads, changes what a build makes
## of the root.
struct Site
  build: String
  beside: Bool
  libs_dir: String
  binary: String
  inputs: String
end

## The site of the caches for the real path `real` of a root file. The inputs are read now, before the work, so a file
## that changes while the front end works makes the next lookup miss instead of keeping the old result under the new
## key.
def site(settings: Env.Settings, real: String) -> Result[Site]
  build = try File.stat(settings.self_path, IO_TIMEOUT_MS)
  root_dir = Paths.directory_of(real)
  project = try Project.find(settings.workspace, root_dir, settings.version)
  inputs = try inputs_digest(settings, project)
  libs_dir = Project.library_dir(project, root_dir)
  override = System.env(BUILD_VARIABLE)
  build_dir = Paths.join(libs_dir, BUILD_FOLDER)
  beside = true
  if override.ok? and override.unwrap! != ""
    build_dir = override.unwrap!
    beside = false
  end

  ok(
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
def private_kind(path: String, kind: String, user: Int) -> Result[Void]
  info = try File.lstat(path, IO_TIMEOUT_MS)
  return error("#{path} is not a #{kind}") if info.kind != kind

  if user >= 0 and (info.user_id != user or info.mode.bit_and(GROUP_OTHER_WRITE) != 0)
    return error("#{path} is not private to this user")
  end

  ok()
end

# The user id of this process, which no builtin gives: the owner of a file made now with `create_private`, in the first
# temporary folder that takes one. The name is random and the file is new and not followed, so a planted name or link
# cannot give another id; a temporary folder that others can write without the sticky bit could still swap the file
# between the create and the stat, which is a setting of the user's. -1 on Windows, where `user_id` is always 0 and
# means nothing.
def own_user() -> Result[Int]
  return ok(-1) if System.os() == "windows"

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
      _ = File.close(made.unwrap!, IO_TIMEOUT_MS)
      info = File.lstat(made_at, IO_TIMEOUT_MS)
      _ = Path.remove(made_at, IO_TIMEOUT_MS)
      return ok(info.unwrap!.user_id) if info.ok?
    end
  end

  error("cannot find out the user of this process")
end

# A folder that exists must pass private_kind; one that does not is made with `Dir.mkdir_private`, one level only (the
# folders above it are made with the default mode when they are missing). True when it was made now. A folder that
# another run made between the check and the mkdir is one that exists.
def private_folder(path: String, user: Int) -> Result[Bool]
  if File.lstat(path, IO_TIMEOUT_MS).ok?
    try private_kind(path, "directory", user)
    return ok(false)
  end

  above = Paths.directory_of(path)
  if above != ""
    _ = Dir.mkdir(above, IO_TIMEOUT_MS)
  end

  made = Dir.mkdir_private(path, IO_TIMEOUT_MS)
  if !made.ok?
    return error(made.message) if !File.lstat(path, IO_TIMEOUT_MS).ok?

    try private_kind(path, "directory", user)
    return ok(false)
  end

  ok(true)
end

# A new file that only this user can use. `create_private` fails on a name that exists and never follows a link.
def write_private(path: String, data: Bytes) -> Result[Void]
  out = try File.open(path, "create_private", IO_TIMEOUT_MS)
  rest = data
  while rest.size > 0
    written = File.write_bytes(out, rest.take(PIECE), IO_TIMEOUT_MS)
    if !written.ok?
      _ = File.close(out, IO_TIMEOUT_MS)
      return written
    end

    rest = rest.drop(PIECE)
  end

  File.close(out, IO_TIMEOUT_MS)
end

# Puts `data` at `target` through the new private file `temporary` (beside the target, named with TEMP_MARK). A rename
# never replaces (Path.rename), so the old entry is removed first: a reader that comes in between finds none, which is
# a miss, and a run that dies in between leaves no entry. False when anything fails, and then `temporary` is removed:
# a run that lost the race to another one (its rename finds the entry the other made) must not leave its file. The
# write handle is closed by then (write_private closes it on every path).
def install(temporary: String, data: Bytes, target: String) -> Bool
  if !write_private(temporary, data).ok?
    discard(temporary)
    return false
  end

  remove_file(target)
  if !Path.rename(temporary, target, IO_TIMEOUT_MS).ok?
    discard(temporary)
    return false
  end

  true
end

# Removes a temporary file of this run. Only this run opens it, but on Windows a scanner (an antivirus or an indexer)
# can hold a file just written or renamed for a moment, and the removal then fails with a sharing violation; there it
# is tried again a few times. Elsewhere it is tried once: a failure there is permanent. A scanner that shares the file
# for deletion lets the removal succeed and keeps the name in the folder until it lets go, which no retry shortens.
# A file that cannot be removed is left for the sweep.
def discard(path: String) -> Void
  tries = 1
  if System.os() == "windows"
    tries = DISCARD_TRIES
  end

  for attempt in 0...tries
    return if Path.remove(path, IO_TIMEOUT_MS).ok?

    if attempt + 1 < tries
      Task.sleep(DISCARD_PAUSE_MS)
    end
  end
end

# Removes the file, link, FIFO, socket or device at `path` (a link is removed as a link, never followed). A folder in
# its place stays (the rename then fails and the entry is not written): `Path.remove` would delete the whole folder.
def remove_file(path: String) -> Void
  info = File.lstat(path, IO_TIMEOUT_MS)
  if info.ok? and info.unwrap!.kind != "directory"
    _ = Path.remove(path, IO_TIMEOUT_MS)
  end
end

# Removes the temporary files that a run left (it died between the write and the rename) once they are an hour old.
def sweep(folder: String) -> Void
  names = Dir.list(folder, IO_TIMEOUT_MS)
  return if !names.ok?

  now = Time.now_ms() / 1000
  for name in names.unwrap!
    if name.include?(TEMP_MARK)
      path = Paths.join(folder, name)
      info = File.lstat(path, IO_TIMEOUT_MS)
      if info.ok? and info.unwrap!.kind == "file" and now - info.unwrap!.modified_seconds > STALE_TEMP_SECONDS
        _ = Path.remove(path, IO_TIMEOUT_MS)
      end
    end
  end
end

def digest(data: Bytes) -> String = OpenSSL.Digest.sha256_hexdigest(data)

## The words of CC, else the system's compiler: the command a native build runs (io/native_build.agc).
def compiler_words(system: String) -> List[String]
  set = System.env("CC")
  if set.ok?
    words = set.unwrap!.split(" ").filter do |word: String| word != "" end
    return words if words.size > 0
  end

  return ["gcc"] if system == "windows"

  ["cc"]
end

private

# The folder of the project (or of the root file) that holds the build outputs, and the variable that names another
# folder in place of the first.
BUILD_FOLDER = "_build"
BUILD_VARIABLE = "AGENTICA_BUILD_DIR"

# The variables that change what the build of a native module makes (io/native_build.agc).
COMPILER_VARIABLES = ["CC", "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "LIBRARY_PATH"]

# The execute bits of the owner, the group and others (0111).
EXECUTE_BITS = 73

# The files that decide which package or library an import reads, next to the manifest.
MANIFEST_FILE = "agentica.toml"
PROJECT_FILES = [MANIFEST_FILE, "agentica.lock"]

# The write bits of the group and of others (020 and 002).
GROUP_OTHER_WRITE = 18

STALE_TEMP_SECONDS = 3600

# How often, and how far apart, discard tries on Windows to remove a temporary file that cannot be removed yet.
DISCARD_TRIES = 5
DISCARD_PAUSE_MS = 30

# What, besides the files an import reads, changes what a build makes of the root: the environment that places
# libraries and packages, the C compiler a native module builds with (the file it is, `compiler_path`) and its
# search variables (CC, CPATH and the others of io/native_build.agc), and the project (the manifest the build finds
# and its lock).
def inputs_digest(settings: Env.Settings, project: Project.Project) -> Result[String]
  workspace = settings.workspace
  env = settings.env
  parts = ["env #{env.agentica_path}|#{env.xdg_data_home}|#{env.xdg_cache_home}|#{env.home}|#{env.local_app_data}"]
  for name in COMPILER_VARIABLES
    value = System.env(name)
    if value.ok?
      parts = parts.push("#{name} #{value.unwrap!}")
    end
  end

  parts = parts.push("compiler #{compiler_path(env.os)}")

  case project
    Project.Project.Bare -> parts = parts.push("project -")
    Project.Project.Declared(manifest) ->
      parts = parts.push("project #{manifest.dir}")
      for name in PROJECT_FILES
        parts = parts.push("#{name} #{file_digest(workspace, Paths.join(manifest.dir, name))}")
      end

      parts = parts.concat(workspace_parts(workspace, manifest))
  end

  ok(digest(parts.join("\n").bytes))
end

# The C compiler a native build would start, found as libuv's spawn finds it. The key holds every match of PATH as
# "CANDIDATE REAL", so a venv with no compiler keeps the cache and a wrapper such as ccache misses when the next match
# changes; a relative candidate depends on the package root of each build, so only its text goes in.
def compiler_path(system: String) -> String
  name = compiler_words(system)[0]
  windows = system == "windows"
  names = executable_names(name, windows)
  if has_folder?(name, windows)
    return name if !Paths.absolute?(name, windows)

    return executable(names, windows)
  end

  matches(search_folders(system), names, windows).join(" ")
end

# The folders a bare name is looked up in, in order; "" is the working folder.
def search_folders(system: String) -> List[String]
  path = System.env("PATH")
  if system == "windows"
    return [""] if !path.ok?

    folders = windows_entries(path.unwrap!).filter do |folder: String| folder != "" end
    return [""].concat(folders.map do |folder: String| unquote(folder) end)
  end

  return path.unwrap!.split(":") if path.ok?

  ["/usr/bin", "/bin"]
end

# libuv splits a Windows PATH at ";", except inside an entry that starts with a quote, up to its closing quote.
def windows_entries(path: String) -> List[String]
  entries: List[String] = []
  entry = ""
  inside = false
  for piece in path.split(";")
    if inside
      entry = "#{entry};#{piece}"
    else
      entry = piece
    end

    quoted = entry.length > 0 and quote?(entry.at(0))
    inside = quoted and !entry.slice(1, entry.length - 1).include?(entry.at(0))
    if !inside
      entries = entries.push(entry)
    end
  end

  return entries.push(entry) if inside

  entries
end

# Each executable file of `names` in `folders`, as "CANDIDATE REAL"; a relative folder adds its candidate alone.
def matches(folders: List[String], names: List[String], windows: Bool) -> List[String]
  found: List[String] = []
  for folder in folders
    if folder == "" or !Paths.absolute?(folder, windows)
      found = found.push("relative #{folder} #{names[0]}")
      next
    end

    match = executable(names.map do |file: String| Paths.join(folder, file) end, windows)
    if match != ""
      found = found.push(match)
    end
  end

  found
end

# The first of `candidates` that is an executable file, as "CANDIDATE REAL"; "" when none is.
def executable(candidates: List[String], windows: Bool) -> String
  for candidate in candidates
    info = File.stat(candidate, IO_TIMEOUT_MS)
    if info.ok? and info.unwrap!.kind == "file" and (windows or info.unwrap!.mode.bit_and(EXECUTE_BITS) != 0)
      real = Path.real(candidate)
      return "#{candidate} #{real.unwrap!}" if real.ok?
    end
  end

  ""
end

def has_folder?(name: String, windows: Bool) -> Bool
  return name.include?("/") or name.include?("\\") or name.include?(":") if windows

  name.include?("/")
end

# On Windows libuv tries NAME as given only when it has an extension, then NAME.com and NAME.exe.
def executable_names(name: String, windows: Bool) -> List[String]
  return [name] if !windows

  base = name.split("/").last.split("\\").last
  given = base.split(".").drop(1).join(".") != ""
  stem = name
  if !name.end_with?(".")
    stem = "#{name}."
  end

  appended = ["#{stem}com", "#{stem}exe"]
  return [name].concat(appended) if given

  appended
end

# libuv drops one quote at each end of a PATH entry.
def unquote(folder: String) -> String
  text = folder
  if text.length > 0 and quote?(text.at(0))
    text = text.slice(1, text.length - 1)
  end

  if text.length > 0 and quote?(text.at(text.length - 1))
    text = text.slice(0, text.length - 1)
  end

  text
end

def quote?(char: String) -> Bool = char == "\"" or char == "'"

# The workspace of the project (packages/members.agc): the manifest that holds the table, and the manifest of each
# member the lock names, which decide the packages a build reads from the members' folders; the manifest of each `path`
# package likewise. The .agc files of a member or a path are sources of the entry like any other.
def workspace_parts(workspace: Workspace.Workspace, found: Project.Found) -> List[String]
  parts: List[String] = []
  if found.members.root != ""
    manifest = Paths.join(found.members.root, MANIFEST_FILE)
    parts = ["workspace #{found.members.root} #{file_digest(workspace, manifest)}"]
  end

  for locked in found.lock.packages
    if Lock.in_place?(locked)
      folder = Project.folder_of(found.dir, found.members, locked)
      parts = parts.push("member #{folder} #{file_digest(workspace, Paths.join(folder, MANIFEST_FILE))}")
    end
  end

  parts
end

# "-" for a file that is not there.
def file_digest(workspace: Workspace.Workspace, path: String) -> String
  read = workspace.read_bytes.call(path)
  return "-" if !read.ok?

  digest(read.unwrap!)
end
