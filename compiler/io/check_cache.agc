## The check cache of `agentica check` and `agentica type-at` (issue #630) on disk: the entries of checked modules
## (modules/check_cache.agc says what an entry holds and when the core may use it) kept in `_build/check/`, with
## `_build/` in the folder of the project (the nearest agentica.toml) or, with none, beside the root file.
## `AGENTICA_BUILD_DIR` names another folder in place of `_build/`, and `--no-cache` turns the cache off, as for the
## bytecode cache (io/bytecode_cache.agc, whose rules this follows).
##
## There is one file for each source file of the programs checked (a path, or a `std/` name), named by a digest of its
## key, so the folder holds at most one entry for each file and an edit replaces the old entry. A file is a head with
## the key of the run (the format, the version, the size, time and path of the binary, and the digest of the project
## inputs, as the bytecode cache has them) and then the text of the entry. A read compares the head, so an entry made
## by another build or for another project is a miss. The entry says which text it is for and the core compares that
## with the text it read, so the cache is never asked which file changed: a changed file is read in full, and a file
## that is the same is not parsed and checked again.
##
## An entry can make `check` skip the function bodies of a module, so the folder is used only when it is what this
## program made: a real folder (never a link) owned by the user of the process and writable by no one else, and the
## same for every entry (the checks of io/cache_files.agc). The folders are made with `Dir.mkdir_private` and the
## entries are written to a new private file under a random name and renamed into place. An entry is untrusted data:
## the core validates what it reads, and a corrupt one is a miss. Anything that fails turns the cache off for the run,
## or makes one entry a miss; nothing here fails a run.

import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import CheckCache from "../modules/check_cache"
import Workspace from "../modules/workspace"
import CacheFiles from "cache_files"
import RandomName from "random_name"

# The folder of the entries, in the build folder.
CHECK_FOLDER = "check"

# The first line of the head of an entry; change it when the layout of a file changes.
FORMAT = "agentica-check-cache-1"

# The characters of the digest in the name of an entry, and its ending.
NAME_CHARS = 32
ENTRY_END = ".chk"

## Where the entries of one run are, what their head must say, and whether the folder exists and may be trusted now
## (`present`; a folder that is missing is made by the first write).
export struct Plan
  build: String
  folder: String
  head: String
  inputs: String
  beside: Bool
  user: Int
  present: Bool
end

## `settings` with the check cache of the project of the root file `root` in its Workspace, or `settings` as they are
## when there is no cache to use: `wanted` is false for `--no-cache`, the front end was not started by the binary or
## reads a stdlib/ folder, or the folder is not one that can be trusted.
export def attach(settings: Env.Settings, root: String, wanted: Bool) -> Env.Settings
  planned = plan(settings, root, wanted)
  if !planned.ok?
    return settings
  end

  return settings.with(workspace: settings.workspace.with(check_cache: port(planned.unwrap!)))
end

## The plan for the root file `root` (as typed).
export def plan(settings: Env.Settings, root: String, wanted: Bool) -> Result[Plan]
  if !wanted or settings.self_path == ""
    return error("the cache is off")
  end

  case settings.std
    Env.StdProvider.Folder(_) -> return error("the front end reads a stdlib folder")
    Env.StdProvider.Embedded -> return planned(settings, root)
  end
end

# The plan of a front end that is the binary's: the site of the project, the user of the process and the state of the
# folders. A root that cannot be resolved, or has a line feed in its path, has no plan.
def planned(settings: Env.Settings, root: String) -> Result[Plan]
  real = try settings.workspace.real_path.call(root)
  if real.contains?("\n")
    return error("the path has a line feed")
  end

  site = try CacheFiles.site(settings, real)
  user = try CacheFiles.own_user()
  folder = Paths.join(site.build, CHECK_FOLDER)
  present = try folders_present(site.build, folder, user)
  head = [FORMAT, "version #{settings.version}", site.binary, site.inputs].join("\n")
  return ok(
    Plan(
      build: site.build,
      folder: folder,
      head: head,
      inputs: site.inputs,
      beside: site.beside,
      user: user,
      present: present,
    ),
  )
end

# Whether the folders exist and are private (a folder that is there and is not private is an error: the cache is off),
# false when `check/` is missing, which a write makes.
def folders_present(build: String, folder: String, user: Int) -> Result[Bool]
  if !File.lstat(build, CacheFiles.IO_TIMEOUT_MS).ok? or !File.lstat(folder, CacheFiles.IO_TIMEOUT_MS).ok?
    return ok(false)
  end

  try CacheFiles.private_kind(build, "directory", user)
  try CacheFiles.private_kind(folder, "directory", user)
  return ok(true)
end

# The check cache a Workspace holds: reads and writes of the entries of `plan`. A block is a function value only as the
# block of a call, so the helpers below hand it back.
def port(plan: Plan) -> Workspace.CheckCache
  return Workspace.CheckCache(
    on: true,
    read: as_reader() do |key: String| read_entry(plan, key) end,
    write: as_writer() do |key: String, text: String| write_entry(plan, key, text) end,
  )
end

def as_reader(f: Fn[String, Result[String]]) -> Fn[String, Result[String]]
  return f
end

def as_writer(f: Fn[String, String, Bool]) -> Fn[String, String, Bool]
  return f
end

# The path of the entry for the file `key`. The name holds the project inputs too, so two projects that share a build
# folder (AGENTICA_BUILD_DIR) do not replace each other's entries for a file they both import.
def entry_path(plan: Plan, key: String) -> String
  name = CacheFiles.digest((CheckCache.piece(plan.inputs) + key).bytes).slice(0, NAME_CHARS)
  return Paths.join(plan.folder, "#{name}#{ENTRY_END}")
end

# The text of the entry for `key` when the file is a regular file of this user that no one else can write, was made
# for this run (the head) and File.read_text takes it (it stops at 1 MiB: the entry of a larger file is a miss).
def read_entry(plan: Plan, key: String) -> Result[String]
  if !plan.present
    return error("there is no entry")
  end

  path = entry_path(plan, key)
  try CacheFiles.private_kind(path, "file", plan.user)
  text = try File.read_text(path, CacheFiles.IO_TIMEOUT_MS)
  wanted = "#{plan.head}\n"
  if !text.starts_with?(wanted)
    return error("the entry is for another build or project")
  end

  return ok(text.slice(wanted.length, text.length - wanted.length))
end

# Replaces the entry for `key`. The entry is written to a new private file beside its place and renamed there; a
# rename never replaces (Path.rename), so the old entry is removed first: a reader that comes in between finds none,
# which is a miss, and a run that dies in between leaves no entry. False when anything fails.
def write_entry(plan: Plan, key: String, text: String) -> Bool
  if !prepare(plan).ok?
    return false
  end

  CacheFiles.sweep(plan.folder)
  suffix = RandomName.hex()
  if !suffix.ok?
    return false
  end

  path = entry_path(plan, key)
  temporary = "#{path}#{CacheFiles.TEMP_MARK}#{suffix.unwrap!}"
  return CacheFiles.install(temporary, "#{plan.head}\n#{text}".bytes, path)
end

# Both folders must be ones this program may trust, or be made now. The .gitignore goes in `_build/` when the cache
# makes it there.
def prepare(plan: Plan) -> Result[Void]
  made = try CacheFiles.private_folder(plan.build, plan.user)
  if made and plan.beside
    CacheFiles.write_private(Paths.join(plan.build, ".gitignore"), "*\n".bytes)
  end

  try CacheFiles.private_folder(plan.folder, plan.user)
  return ok()
end
