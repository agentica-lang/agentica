## The bytecode cache of `agentica FILE.agc` and `agentica test` (issue #375): the compiled program of a root file is
## kept in `.agc_cache/` next to it (the folder `AGENTICA_CACHE_DIR` names, when set), so a run whose sources did not
## change starts without the front end.
##
## An entry is one file: a head `AGCCACHE NNNNNNNN\n` with the byte length of the text that follows, that text, then
## the bytes of the program, the same ones `agentica compile` writes. The text has one line for each part of the key
## (the format, the version and build of the binary, the real path of the root, and a digest of what decides which
## files an import reads), then `program SHA256`, then one `source SHA256 PATH` line for every file of the user that
## the front end read. A lookup compares the key, hashes those files again and the program bytes, and any difference
## is a miss, so the entry is rebuilt. Nothing in an entry is trusted: the bytes go through the loader like any .agcb.
##
## The build id is the size and the modification time of the binary: a build of this checkout that changes the front
## end or the std/ sources changes the file. std/ sources are inside the binary, so they are not in the list. No flag
## of the command line changes the bytes of the program (--dump and --dump-ir do not compile to bytes), so none is in
## the key.
##
## Nothing here fails a run: a folder that cannot be written, an entry that cannot be read or a file that is gone is a
## miss, and the program is compiled as without the cache. This is front-end I/O, so the --deny-* flags (which are for
## the program) do not reach it.

import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Linker from "../modules/linker"
import Resolve from "../modules/resolve_import"
import Workspace from "../modules/workspace"
import PackageHash from "../packages/package_hash"
import Project from "../packages/project"
import SaveFile from "save_file"

# The folder next to the root file, and the variable that names another one.
CACHE_FOLDER = ".agc_cache"
CACHE_VARIABLE = "AGENTICA_CACHE_DIR"

# The first line of the key; change it when the layout of an entry changes.
FORMAT = "agentica-cache-1"

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

# A line of the text for a source file: "source ", the digest in hex, a space, the path.
SOURCE_WORD = "source "
DIGEST_CHARS = 64

# The files that decide which package or library an import reads, next to the manifest.
PROJECT_FILES = ["agentica.toml", "agentica.lock"]

## Where the entry of one root file is and what it must match. `beside` is true for the `.agc_cache/` folder next to
## the sources, false for the folder of AGENTICA_CACHE_DIR.
export struct Entry
  folder: String
  file: String
  key: String
  beside: Bool
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

## The program kept for the plan, if the sources are the ones it was made from.
export def lookup(plan: Plan, settings: Env.Settings) -> Lookup
  case plan
    Plan.Off -> return Lookup.Miss
    Plan.On(entry) ->
      found = read_entry(entry, settings.workspace)
      if found.ok?
        return Lookup.Hit(found.unwrap!)
      end
      return Lookup.Miss
  end
end

## Keeps `program`, which was compiled from `modules`, as the entry of the plan. It gives false when it could not (a
## folder that is not writable); the run goes on either way.
export def store(plan: Plan, modules: List[Linker.LinkedModule], program: List[Int]) -> Bool
  case plan
    Plan.Off -> return false
    Plan.On(entry) ->
      sources = modules.filter do |module: Linker.LinkedModule| !Resolve.embedded?(module.key) end
      lines = sources.map do |module: Linker.LinkedModule| source_line(module) end
      text = [entry.key, "program #{digest(program)}"].concat(lines).join("\n")
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
  inputs = try inputs_digest(settings, Paths.directory_of(real))
  key = [
    FORMAT,
    "version #{settings.version}",
    "build #{build.size_bytes}-#{build.modified_seconds}",
    "root #{real}",
    "inputs #{inputs}",
  ].join("\n")
  override = System.env(CACHE_VARIABLE)
  folder = Paths.join(Paths.directory_of(real), CACHE_FOLDER)
  beside = true
  if override.ok? and override.unwrap! != ""
    folder = override.unwrap!
    beside = false
  end
  name = "#{Paths.last_part(real)}-#{digest(String.to_bytes(real)).slice(0, 16)}.agcb"
  return ok(Entry(folder: folder, file: Paths.join(folder, name), key: key, beside: beside))
end

# What, besides the files an import reads, changes what a build makes of the root: the environment that places
# libraries and packages, the project (the manifest the build finds and its lock) and the .agc files of the folders
# `pkg/` imports search, whose names decide which of two files an import reads.
def inputs_digest(settings: Env.Settings, root_dir: String) -> Result[String]
  workspace = settings.workspace
  env = settings.env
  project = try Project.find(workspace, root_dir)
  found = Project.library_dir(project, root_dir)
  parts = ["env #{env.agentica_path}|#{env.xdg_data_home}|#{env.xdg_cache_home}|#{env.home}|#{env.local_app_data}"]
  case project
    Project.Project.Bare -> parts = parts.push("project -")
    Project.Project.Declared(manifest) ->
      parts = parts.push("project #{manifest.dir}")
      for name in PROJECT_FILES
        parts = parts.push("#{name} #{file_digest(workspace, Paths.join(manifest.dir, name))}")
      end
  end
  roots = try Resolve.search_roots(settings, found)
  for folder in roots
    parts = parts.push("names #{folder} #{names_digest(workspace, folder)}")
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

# The digest of the names of the .agc files under a folder, or "-" for a folder that cannot be listed.
def names_digest(workspace: Workspace.Workspace, folder: String) -> String
  case PackageHash.list_files(workspace, folder)
    PackageHash.Listing.Stopped(_) -> return "-"
    PackageHash.Listing.Files(names) -> return digest(String.to_bytes(names.sort.join("\n")))
  end
end

def read_entry(entry: Entry, workspace: Workspace.Workspace) -> Result[List[Int]]
  handle = try File.open(entry.file, "read", IO_TIMEOUT_MS)
  read = read_whole(handle, entry, workspace)
  File.close(handle, IO_TIMEOUT_MS)
  return read
end

def read_whole(handle: FileHandle, entry: Entry, workspace: Workspace.Workspace) -> Result[List[Int]]
  head = try read_exact(handle, HEAD_BYTES)
  size = try text_size(head)
  bytes = try read_exact(handle, size)
  text = try String.from_bytes(bytes)
  if !text.starts_with?("#{entry.key}\nprogram ")
    return error("the entry is for another build or program")
  end
  # The key has no line feed inside a line, so its lines are the first ones of the text, then the program line.
  lines = text.split("\n").drop(entry.key.split("\n").size)
  try check_sources(workspace, lines.drop(1))
  program = try read_rest(handle)
  if lines[0] != "program #{digest(program)}"
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

# Every source file must still have the digest the entry holds.
def check_sources(workspace: Workspace.Workspace, lines: List[String]) -> Result[Void]
  for line in lines
    if line.length <= SOURCE_WORD.length + DIGEST_CHARS + 1 or !line.starts_with?(SOURCE_WORD)
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
  end
  return ok()
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

# Writes the entry to a file beside its place and renames it there (SaveFile.replace), so a reader sees the old entry
# or the new one, and two runs that write together leave one of them. The folder made next to the sources gets a
# .gitignore of its own, so the bytecode is not committed by mistake.
def publish(entry: Entry, text: String, program: List[Int]) -> Bool
  if !Dir.mkdir(entry.folder, IO_TIMEOUT_MS).ok?
    return false
  end
  if entry.beside
    ignore = Paths.join(entry.folder, ".gitignore")
    if !File.stat(ignore, IO_TIMEOUT_MS).ok?
      File.write_text(ignore, "*\n", IO_TIMEOUT_MS)
    end
  end
  body = String.to_bytes(text)
  data = String.to_bytes(head(body.size)).concat(body).concat(program)
  replacing = File.stat(entry.file, IO_TIMEOUT_MS).ok?
  return SaveFile.replace(entry.file, data, replacing, IO_TIMEOUT_MS).ok?
end

def head(size: Int) -> String
  digits = size.to_s
  while digits.length < HEAD_DIGITS
    digits = "0#{digits}"
  end
  return "#{HEAD_WORD}#{digits}\n"
end

def digest(data: List[Int]) -> String
  digits = "0123456789abcdef"
  return Crypto.sha256(data).map do |byte: Int| digits.at(byte / 16) + digits.at(byte % 16) end.join("")
end
