## The bytecode cache of `agentica FILE.agc` and `agentica test` (issue #375): the compiled program of a root file is
## kept in `_build/bytecode/`, with `_build/` in the folder of the project (the nearest agentica.toml) or, with none,
## beside the root file. `AGENTICA_BUILD_DIR` names another folder in place of `_build/`. A run whose sources did not
## change starts without the front end.
##
## An entry is one file: a head `AGCCACHE NNNNNNNN\n` with the byte length of the text that follows, that text, then
## the bytes of the program, the same ones `agentica compile` writes. The text has one line for each part of the key
## (the format, the version, build and path of the binary, the real path of the root, and a digest of the project
## inputs), then `program SHA256`, then one `source SHA256 PATH` line for every file of the user that the front end
## read, then the probes of the resolver: `absent PATH` for a place an import looked at and found nothing, and
## `present PATH<TAB>REAL` for a place that held a file, with the real path it led to. A lookup compares the key,
## hashes the files again, checks the probes (`file_exists` and `real_path`, a few `stat`s) and hashes the program, and
## any difference is a miss, so the entry is rebuilt. The probes cover a file that appears in an earlier folder of the
## `pkg/` search and a link that is retargeted (the files of a package in `deps/` are sources, so an edit there is a
## miss); a program with no `pkg/` import records one probe for each relative import.
##
## The program digest only guards against damage. The loader treats the bytes as untrusted, but anything that can
## write the entry can make the user run the bytecode it holds, so the folder and the entry are used only when they
## are what this program made: a real folder and a regular file (never a link), owned by the user of the process, and
## writable by no one else. This holds for `_build/`, for `_build/bytecode/` and for the entry. The folders are made
## with `Dir.mkdir_private` (mode 0700); the entry is written to a new file made with `create_private` (O_EXCL, no
## links, mode 0600) under a random name and renamed into place. On Windows there are no mode bits or owner ids to
## read, so only the link and file-kind checks apply there. Anything that fails these checks turns the cache off for
## the run.
##
## The build id is the size and the modification time (in seconds) of the binary, with its path: a rebuild of this
## checkout changes the file, and the version alone would not. Two builds of one size that are made within a second, or
## a copy that keeps the time, are not told apart, and the check of the header of the program (the version) is what is
## left. std/ sources are inside the binary, so they are not in the list. No flag of the command line changes the
## bytes of the program (--dump and --dump-ir do not compile to bytes), so none is in the key.
##
## The checks are by path (there is no `fstat` on a handle), so a swap of the folder between the check and the open is
## not closed. It needs write access to the parent of the folder: for `_build/` that is the folder of the project,
## whose sources could be edited just as well; for a folder named by AGENTICA_BUILD_DIR the parent must not be
## writable by others (a sticky folder such as /tmp is fine).
##
## Nothing here fails a run: a folder that cannot be written, an entry that cannot be read or a file that is gone is a
## miss, and the program is compiled as without the cache. This is front-end I/O, so the --deny-* flags (which are for
## the program) do not reach it.

import Declarations from "../modules/declarations"
import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Linker from "../modules/linker"
import Resolve from "../modules/resolve_import"
import Workspace from "../modules/workspace"
import PackageHash from "../packages/package_hash"
import Project from "../packages/project"
import RandomName from "random_name"

# The folder of the project (or of the root file) that holds the build outputs, the folder of the entries in it, and
# the variable that names another folder in place of the first.
BUILD_FOLDER = "_build"
BYTECODE_FOLDER = "bytecode"
BUILD_VARIABLE = "AGENTICA_BUILD_DIR"

# The first line of the key; change it when the layout of an entry changes.
FORMAT = "agentica-cache-3"

# The head of an entry: this word, a space, the length of the text in eight digits, a line feed.
HEAD_WORD = "AGCCACHE "
HEAD_DIGITS = 8
HEAD_BYTES = 18

# The text of an entry stays far below this; a head that claims more is not an entry.
MAX_TEXT_BYTES = 16_777_216

# The program is at most as large as the VM takes (AGC_MAX_FILE_BYTES).
MAX_PROGRAM_BYTES = 268_435_456

# The deadline of each system call, in milliseconds, and the most one File.read_bytes gives.
IO_TIMEOUT_MS = 10_000
PIECE = 1_048_576

# The words that start the lines after the program line, and the digest length in hex.
SOURCE_WORD = "source "
ABSENT_WORD = "absent "
PRESENT_WORD = "present "
DIGEST_CHARS = 64

# The files that decide which package or library an import reads, next to the manifest.
PROJECT_FILES = ["agentica.toml", "agentica.lock"]

# The write bits of the group and of others (020 and 002).
GROUP_OTHER_WRITE = 18

# A file that a run could not finish is left with this in its name; the next one to write removes the old ones.
TEMP_MARK = ".agcb.tmp-"
STALE_TEMP_SECONDS = 3600

# The first bytes of a program: the magic, then the format version (4 bytes), then the length of the Agentica version
# (4 bytes, little endian) and the version.
MAGIC = "AGCB"
VERSION_AT = 12

## Where the entry of one root file is and what it must match. `build` is the `_build/` folder and `folder` the
## `bytecode/` folder in it. `beside` is true for `_build/` of the project, false for the folder of AGENTICA_BUILD_DIR.
## `libs_dir` is the folder whose agc_libs/ the build reads first (the probes of the `pkg/` imports start there).
export struct Entry
  build: String
  folder: String
  file: String
  key: String
  beside: Bool
  libs_dir: String
end

## The cache for one root file: off (asked off, no place for it, or a run that is not of the binary), or on with its
## entry.
export enum Plan
  Off
  On(Entry)
end

## What a lookup found: the bytes of the program, or nothing usable.
export enum Lookup
  Hit(List[Int])
  Miss
end

## The plan for the root file `root` (as typed). `wanted` is false for `--no-cache`. The cache is off for a front end
## that was not started by the binary (no `self_path`, or a stdlib/ folder instead of the embedded std/ sources), for a
## root that cannot be resolved and for a project whose manifest or lock is not good: the front end then says why.
export def plan(settings: Env.Settings, root: String, wanted: Bool) -> Plan
  if !wanted or settings.self_path == ""
    return Plan.Off
  end
  case settings.std
    Env.StdProvider.Folder(_) -> return Plan.Off
    Env.StdProvider.Embedded ->
      made = entry_for(settings, root)
      if made.ok?
        return Plan.On(made.unwrap!)
      end
      return Plan.Off
  end
end

## The program kept for the plan, if the sources are the ones it was made from and the entry is the program's own.
export def lookup(plan: Plan, settings: Env.Settings) -> Lookup
  case plan
    Plan.Off -> return Lookup.Miss
    Plan.On(entry) ->
      found = read_entry(entry, settings)
      if found.ok?
        return Lookup.Hit(found.unwrap!)
      end
      return Lookup.Miss
  end
end

## Keeps `program`, which was compiled from `modules`, as the entry of the plan. It gives false when it could not (a
## folder that is not safe or not writable); the run goes on either way. The probes are taken here, after the compile,
## so a file that appears between the two is the one gap: it is seen as present, not as absent.
export def store(plan: Plan, settings: Env.Settings, modules: List[Linker.LinkedModule], program: List[Int]) -> Bool
  case plan
    Plan.Off -> return false
    Plan.On(entry) ->
      sources = modules.filter do |module: Linker.LinkedModule| !Resolve.embedded?(module.key) end
      probes = probe_lines(settings, entry.libs_dir, sources)
      if !probes.ok?
        return false
      end
      lines = sources.map do |module: Linker.LinkedModule| source_line(module) end
      text = [entry.key, "program #{digest(program)}"].concat(lines).concat(probes.unwrap!).join("\n")
      return publish(entry, text, program)
  end
end

def source_line(module: Linker.LinkedModule) -> String
  return "#{SOURCE_WORD}#{digest(String.to_bytes(module.text))} #{module.key}"
end

# The place of the entry and the key it must match. The inputs are read now, before the compile, so a file that changes
# while the front end works makes the next lookup miss instead of keeping the old program under the new key.
def entry_for(settings: Env.Settings, root: String) -> Result[Entry]
  real = try settings.workspace.real_path.call(root)
  if real.contains?("\n")
    return error("the path has a line feed")
  end
  build = try File.stat(settings.self_path, IO_TIMEOUT_MS)
  root_dir = Paths.directory_of(real)
  project = try Project.find(settings.workspace, root_dir)
  inputs = try inputs_digest(settings, project)
  key = [
    FORMAT,
    "version #{settings.version}",
    "build #{build.size_bytes}-#{build.modified_seconds} #{settings.self_path}",
    "root #{real}",
    "inputs #{inputs}",
  ].join("\n")
  libs_dir = Project.library_dir(project, root_dir)
  override = System.env(BUILD_VARIABLE)
  build_dir = Paths.join(libs_dir, BUILD_FOLDER)
  beside = true
  if override.ok? and override.unwrap! != ""
    build_dir = override.unwrap!
    beside = false
  end
  folder = Paths.join(build_dir, BYTECODE_FOLDER)
  name = "#{Paths.last_part(real)}-#{digest(String.to_bytes(real)).slice(0, 16)}.agcb"
  return ok(
    Entry(
      build: build_dir,
      folder: folder,
      file: Paths.join(folder, name),
      key: key,
      beside: beside,
      libs_dir: libs_dir,
    ),
  )
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
  end
  return ok(digest(String.to_bytes(parts.join("\n"))))
end

# "-" for a file that is not there.
def file_digest(workspace: Workspace.Workspace, path: String) -> String
  read = workspace.read_bytes.call(path)
  if !read.ok?
    return "-"
  end
  return digest(read.unwrap!)
end

# What the resolver looked at for the imports of `modules`, as lines of the entry: for a `pkg/` import, every place of
# the search (a place that holds a file is `present`, with its real path); for any other import, the path written
# beside the importing file and the real path it leads to (a link may be retargeted). std/ imports are in the binary.
# More places than the resolver took are listed (it stops at the first), which can only cost a miss.
def probe_lines(settings: Env.Settings, libs_dir: String, modules: List[Linker.LinkedModule]) -> Result[List[String]]
  workspace = settings.workspace
  roots: List[String] = []
  searched = false
  lines: List[String] = []
  for module in modules
    for decl in Declarations.imports_of(module.parsed.declarations)
      file = "#{decl.path}.agc"
      if file.starts_with?("std/")
        next
      elsif file.starts_with?("pkg/")
        if !searched
          roots = try Resolve.search_roots(settings, libs_dir)
          searched = true
        end
        for root in roots
          lines = lines.push(try probe(workspace, Paths.join(root, file.slice(4, file.length - 4))))
        end
      else
        lines = lines.push(try probe(workspace, Paths.join(Paths.directory_of(module.key), file)))
      end
    end
  end
  return ok(lines.uniq)
end

# The line for one place. A path with a line feed or a tab would break the lines; it keeps the entry from being made.
def probe(workspace: Workspace.Workspace, path: String) -> Result[String]
  if !plain?(path)
    return error("the path has a line feed, a tab or a NUL")
  end
  if !workspace.file_exists.call(path)
    return ok("#{ABSENT_WORD}#{path}")
  end
  real = try workspace.real_path.call(path)
  if !plain?(real)
    return error("the path has a line feed, a tab or a NUL")
  end
  return ok("#{PRESENT_WORD}#{path}\t#{real}")
end

def plain?(path: String) -> Bool
  return !path.contains?("\n") and !path.contains?("\t") and !path.contains?(String.from_code(0))
end

def read_entry(entry: Entry, settings: Env.Settings) -> Result[List[Int]]
  user = try own_user()
  try private_kind(entry.build, "directory", user)
  try private_kind(entry.folder, "directory", user)
  try private_kind(entry.file, "file", user)
  handle = try File.open(entry.file, "read", IO_TIMEOUT_MS)
  read = read_whole(handle, entry, settings)
  File.close(handle, IO_TIMEOUT_MS)
  return read
end

# The folder or the file at `path` must be of this `kind` as it stands (File.lstat: a link is its own kind and is
# refused) and, where the system has owners and modes (`user` is not -1), be owned by the user of this process and
# writable by no one else. On Windows any real folder and file pass: nothing tells whose they are (an owner or ACL
# check and a Windows test of the link and kind checks are open in #568).
def private_kind(path: String, kind: String, user: Int) -> Result[Void]
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
def own_user() -> Result[Int]
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

def read_whole(handle: FileHandle, entry: Entry, settings: Env.Settings) -> Result[List[Int]]
  head = try read_exact(handle, HEAD_BYTES)
  size = try text_size(head)
  bytes = try read_exact(handle, size)
  text = try String.from_bytes(bytes)
  if !text.starts_with?("#{entry.key}\nprogram ")
    return error("the entry is for another build or program")
  end
  # The key has no line feed inside a line, so its lines are the first ones of the text, then the program line.
  lines = text.split("\n").drop(entry.key.split("\n").size)
  try check_lines(settings.workspace, lines.drop(1))
  program = try read_rest(handle)
  if lines[0] != "program #{digest(program)}" or !made_by?(program, settings.version)
    return error("the program of the entry is damaged")
  end
  return ok(program)
end

# The length that the head of an entry gives.
def text_size(head: List[Int]) -> Result[Int]
  text = try String.from_bytes(head)
  # The length is checked in characters: a head with a multi-byte character is shorter and not an entry.
  if text.length != HEAD_BYTES or !text.starts_with?(HEAD_WORD) or !text.ends_with?("\n")
    return error("not a cache entry")
  end
  size = try text.slice(HEAD_WORD.length, HEAD_DIGITS).to_int
  if size < 0 or size > MAX_TEXT_BYTES
    return error("the head of the entry is wrong")
  end
  return ok(size)
end

# Every source file must still have the digest the entry holds, and every probe must still answer as it did.
def check_lines(workspace: Workspace.Workspace, lines: List[String]) -> Result[Void]
  for line in lines
    if line.starts_with?(SOURCE_WORD)
      try check_source(workspace, line)
    elsif line.starts_with?(ABSENT_WORD)
      path = line.slice(ABSENT_WORD.length, line.length - ABSENT_WORD.length)
      if path.contains?(String.from_code(0)) or workspace.file_exists.call(path)
        return error("a place that was empty has a file now")
      end
    elsif line.starts_with?(PRESENT_WORD)
      try check_present(workspace, line.slice(PRESENT_WORD.length, line.length - PRESENT_WORD.length))
    else
      return error("a line of the entry is wrong")
    end
  end
  return ok()
end

def check_source(workspace: Workspace.Workspace, line: String) -> Result[Void]
  if line.length <= SOURCE_WORD.length + DIGEST_CHARS + 1
    return error("a line of the entry is wrong")
  end
  wanted = line.slice(SOURCE_WORD.length, DIGEST_CHARS)
  from = SOURCE_WORD.length + DIGEST_CHARS + 1
  path = line.slice(from, line.length - from)
  # A path with a NUL is a contract error of the File calls, which would end the front end.
  if path.contains?(String.from_code(0))
    return error("a line of the entry is wrong")
  end
  read = try workspace.read_bytes.call(path)
  if digest(read) != wanted
    return error("#{path} changed")
  end
  return ok()
end

# `PATH<TAB>REAL`: the path must still lead to the same file.
def check_present(workspace: Workspace.Workspace, rest: String) -> Result[Void]
  parts = rest.split("\t")
  if parts.size != 2 or parts[0].contains?(String.from_code(0))
    return error("a line of the entry is wrong")
  end
  real = try workspace.real_path.call(parts[0])
  if real != parts[1]
    return error("#{parts[0]} leads somewhere else")
  end
  return ok()
end

# Whether the bytes begin as a program of this version does (the check that an entry of another build, with the same
# size and time, is not run): the magic, and the version text after the format number and the length.
def made_by?(program: List[Int], version: String) -> Bool
  wanted = String.to_bytes(version)
  if program.size < VERSION_AT + wanted.size or program[8] != wanted.size
    return false
  end
  magic = String.from_bytes(program.take(MAGIC.length))
  found = String.from_bytes(program.take(VERSION_AT + wanted.size).drop(VERSION_AT))
  return magic.ok? and magic.unwrap! == MAGIC and found.ok? and found.unwrap! == version
end

# Exactly `count` bytes, or an error when the file ends first.
def read_exact(handle: FileHandle, count: Int) -> Result[List[Int]]
  pieces: List[List[Int]] = []
  left = count
  while left > 0
    got = try File.read_bytes(handle, piece(left), IO_TIMEOUT_MS)
    if got.size == 0
      return error("the entry ends too soon")
    end
    pieces = pieces.push(got)
    left -= got.size
  end
  return ok(PackageHash.concat_all(pieces))
end

def piece(left: Int) -> Int
  if left < PIECE
    return left
  end
  return PIECE
end

# The rest of the file, up to the size the VM takes.
def read_rest(handle: FileHandle) -> Result[List[Int]]
  pieces: List[List[Int]] = []
  total = 0
  finished = false
  while !finished
    got = try File.read_bytes(handle, PIECE, IO_TIMEOUT_MS)
    total += got.size
    if total > MAX_PROGRAM_BYTES
      return error("the program of the entry is too large")
    end
    finished = got.size == 0
    pieces = pieces.push(got)
  end
  return ok(PackageHash.concat_all(pieces))
end

# Writes the entry to a new private file beside its place under a name nobody can guess, and renames it there. A
# rename never replaces (Path.rename), so the old entry is removed first: a reader that comes in between finds none,
# which is a miss, and a run that dies in between leaves no entry. A file system that cannot rename without replacing
# (the rename then fails) never gets an entry; the run is not affected. A `_build/` made by the cache gets a
# .gitignore of its own, so the bytecode is not committed by mistake.
def publish(entry: Entry, text: String, program: List[Int]) -> Bool
  if !prepare_folder(entry).ok?
    return false
  end
  suffix = RandomName.hex()
  if !suffix.ok?
    return false
  end
  body = String.to_bytes(text)
  data = String.to_bytes(head(body.size)).concat(body).concat(program)
  temporary = Paths.join(entry.folder, "#{Paths.last_part(entry.file)}.tmp-#{suffix.unwrap!}")
  if !write_private(temporary, data).ok?
    Path.remove(temporary, IO_TIMEOUT_MS)
    return false
  end
  sweep(entry.folder)
  remove_file(entry.file)
  if !Path.rename(temporary, entry.file, IO_TIMEOUT_MS).ok?
    Path.remove(temporary, IO_TIMEOUT_MS)
    return false
  end
  return true
end

# Both folders must be ones this program may trust (private_kind), or be made now. The .gitignore goes in `_build/`
# when the cache makes it there.
def prepare_folder(entry: Entry) -> Result[Void]
  made = try private_folder(entry.build)
  if made and entry.beside
    write_private(Paths.join(entry.build, ".gitignore"), String.to_bytes("*\n"))
  end
  try private_folder(entry.folder)
  return ok()
end

# A folder that exists must pass private_kind; one that does not is made with `Dir.mkdir_private`, one level only (the
# folders above it are made with the default mode when they are missing). True when it was made now.
def private_folder(path: String) -> Result[Bool]
  if File.lstat(path, IO_TIMEOUT_MS).ok?
    user = try own_user()
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
def write_private(path: String, data: List[Int]) -> Result[Void]
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

# Removes the file or the link at `path` (a link is removed as a link, never followed). A folder in its place stays
# (the rename then fails and the entry is not written): `Path.remove` would delete the whole folder.
def remove_file(path: String) -> Void
  info = File.lstat(path, IO_TIMEOUT_MS)
  if info.ok? and (info.unwrap!.kind == "file" or info.unwrap!.kind == "link")
    Path.remove(path, IO_TIMEOUT_MS)
  end
end

# Removes the temporary files that a run left (it died between the write and the rename) once they are an hour old.
def sweep(folder: String) -> Void
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

def head(size: Int) -> String
  digits = size.to_s
  while digits.length < HEAD_DIGITS
    digits = "0#{digits}"
  end
  return "#{HEAD_WORD}#{digits}\n"
end

def digest(data: List[Int]) -> String
  return RandomName.hex_of(Crypto.sha256(data))
end
