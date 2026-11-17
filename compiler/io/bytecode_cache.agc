## The bytecode cache of `agentica FILE.agc`, `agentica compile` and `agentica test` (issue #375); where it lives and
## the user-facing rules are in site/content/cli.md, "Bytecode cache". A run whose sources did not change starts
## without the front end.
##
## An entry is one file: a head `AGCCACHE NNNNNNNN\n` with the byte length of the text that follows, that text, then
## the bytes of the program, the same ones `agentica compile` writes. The text has one line for each part of the key
## (the format, the version, build and path of the binary, the real path of the root, and a digest of the project
## inputs), then `program SHA256`, then one `source SHA256 PATH` line for every file of the user that the front end
## read, then `compiler SHA256` (the C compiler and its search variables) when the program has a native module, so
## only such a program looks for the compiler at a start, then the probes of the resolver: `absent PATH` for a place
## an import looked at and found nothing, and `present PATH<TAB>REAL` for a place that held a file, with the real
## path it led to. A lookup compares the key, hashes the files again, checks the probes (`file_exists` and
## `real_path`, a few `stat`s) and hashes the program, and any difference is a miss, so the entry is rebuilt. The
## probes cover a file that appears in an earlier folder of the `pkg/` search and a link that is retargeted (the files
## of a package in `deps/` are sources, so an edit there is a miss); a program with no `pkg/` import records one probe
## for each relative import.
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
## bytes of the program (--dump and --dump-ir do not compile to bytes), so none is in the key; a test file compiled for
## `agentica test` has its own key and entry (`test PATH` in place of `root PATH`).
##
## The checks are by path (there is no `fstat` on a handle), so a swap of the folder between the check and the open is
## not closed. It needs write access to the parent of the folder: for `_build/` that is the folder of the project,
## whose sources could be edited just as well; for a folder named by AGENTICA_BUILD_DIR the parent must not be
## writable by others (a sticky folder such as /tmp is fine).
##
## Nothing here fails a run: a folder that cannot be written, an entry that cannot be read or a file that is gone is a
## miss, and the program is compiled as without the cache. This is front-end I/O, so the --deny-* flags (which are for
## the program) do not reach it.
##
## This file plans and reads an entry; io/bytecode_store.agc makes and writes one.

import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Workspace from "../modules/workspace"
import NativeBuild from "../packages/native_build"
import PackageHash from "../packages/package_hash"
import CacheFiles from "cache_files"

## The words that start the lines after the program line.
SOURCE_WORD = "source "
TREE_WORD = "tree "
COMPILER_WORD = "compiler "
ABSENT_WORD = "absent "
PRESENT_WORD = "present "

## Where the entry of one root file is and what it must match. `build` is the `_build/` folder and `folder` the
## `bytecode/` folder in it. `beside` is true for `_build/` of the project, false for the folder of AGENTICA_BUILD_DIR.
## `libs_dir` is the folder whose agc_libs/ the build reads first (the probes of the `pkg/` imports start there).
## `compiler` is the compiler line (CacheFiles.compiler_line) as a miss read it, before the compile; "" until then.
struct Entry
  build: String
  folder: String
  file: String
  key: String
  beside: Bool
  libs_dir: String
  compiler: String
end

## The cache for one root file: off (asked off, no place for it, or a run that is not of the binary), or on with its
## entry.
enum Plan
  Off
  On(Entry)
end

## What a lookup found: the bytes of the program, or nothing usable, with the plan to store the compiled program
## with. That plan holds the compiler line, read now, so a compiler that changes while the front end works makes the
## next lookup miss.
enum Lookup
  Hit(Bytes)
  Miss(Plan)
end

## The plan for the root file `root` (as typed). `wanted` is false for `--no-cache`. The cache is off for a front end
## that was not started by the binary (no `self_path`, or a stdlib/ folder instead of the embedded std/ sources), for a
## root that cannot be resolved and for a project whose manifest or lock is not good: the front end then says why.
def plan(settings: Env.Settings, root: String, wanted: Bool) -> Plan
  return Plan.Off if !wanted or settings.self_path == ""

  case settings.std
    Env.StdProvider.Folder(_) -> Plan.Off
    Env.StdProvider.Embedded ->
      made = entry_for(settings, root)
      return Plan.On(made.unwrap!) if made.ok?

      Plan.Off
  end
end

## The program kept for the plan, if the sources are the ones it was made from and the entry is the program's own.
def lookup(plan: Plan, settings: Env.Settings) -> Lookup
  case kept(plan, settings)
    some(bytes) -> Lookup.Hit(bytes)
    none -> Lookup.Miss(missed(plan, settings))
  end
end

## The plan to store with after a miss: it holds the compiler line, read now, before the compile.
def missed(plan: Plan, settings: Env.Settings) -> Plan
  case plan
    Plan.Off -> plan
    Plan.On(entry) -> Plan.On(entry.with(compiler: CacheFiles.compiler_line(settings.env.os)))
  end
end

## The program of a hit, as `lookup` finds it, and nothing more: a miss here reads no compiler line, so the launcher
## (app/cli_hit.agc) can leave the miss to the front end.
def kept(plan: Plan, settings: Env.Settings) -> Optional[Bytes]
  case plan
    Plan.Off -> none
    Plan.On(entry) ->
      found = read_entry(entry, settings)
      return some(found.unwrap!) if found.ok?

      none
  end
end

## The digest of the names of the native/ files of a package folder: those the package hash covers, and those the walk
## of a build reads (hidden ones too; a refused walk is its failure), so a new file of either kind is a miss.
def names_digest(workspace: Workspace.Workspace, root: String) -> String
  hashed = PackageHash.native_files(workspace, root).join("\n")
  walked = ""
  case NativeBuild.native_files(workspace, root, "", "")
    ok(paths) -> walked = paths.join("\n")
    error(packed) -> walked = "refused #{packed}"
  end

  CacheFiles.digest("#{hashed}\n\n#{walked}".bytes)
end

## The head of an entry whose text has `size` bytes.
def head(size: Int) -> String
  digits = size.to_s
  while digits.length < HEAD_DIGITS
    digits = "0#{digits}"
  end

  "#{HEAD_WORD}#{digits}\n"
end

private

# The folder of the entries, in the build folder (io/cache_files.agc).
BYTECODE_FOLDER = "bytecode"

# The first line of the key; change it when the layout of an entry changes.
FORMAT = "agentica-cache-4"

# The head of an entry: this word, a space, the length of the text in eight digits, a line feed.
HEAD_WORD = "AGCCACHE "
HEAD_DIGITS = 8
HEAD_BYTES = 18

# The text of an entry stays far below this; a head that claims more is not an entry.
MAX_TEXT_BYTES = 16_777_216

# The program is at most as large as the VM takes (AGC_MAX_FILE_BYTES).
MAX_PROGRAM_BYTES = 268_435_456

# The digest length in hex.
DIGEST_CHARS = 64

# The first bytes of a program: the magic, then the format version (4 bytes), then the length of the Agentica version
# (4 bytes, little endian) and the version.
MAGIC = "AGCB"
VERSION_AT = 12

# The place of the entry and the key it must match. The inputs are read now, before the compile, so a file that changes
# while the front end works makes the next lookup miss instead of keeping the old program under the new key.
def entry_for(settings: Env.Settings, root: String) -> Result[Entry]
  real = try settings.workspace.real_path.call(root)
  return error("the path has a line feed") if real.include?("\n")

  site = try CacheFiles.site(settings, real)
  # A test file compiled for `agentica test` gets a `main` that a run does not (Settings.test_file), so the two have
  # entries of their own.
  root = "root #{real}"
  named = real
  if settings.test_file
    root = "test #{real}"
    named = root
  end

  # A step program may import the test group of the manifest, which a run of the same file may not.
  if settings.test_build
    root = "steps #{root}"
    named = root
  end

  # Under a --deny-* flag no module is built (Settings.native_denied), so the program names a library to build by its
  # bare name, which the VM refuses with the rest of the native code: it has an entry of its own, never a plain run's.
  if settings.native_denied
    root = "denied #{root}"
    named = root
  end

  parts = [FORMAT, "version #{settings.version}", site.binary, root, site.inputs]
  # The native policy of the command line and the environment picks the library of a module, prebuilt or built.
  if settings.native_policy != ""
    parts = parts.push("native policy #{settings.native_policy.replace("\n", " ")}")
  end

  key = parts.join("\n")
  folder = Paths.join(site.build, BYTECODE_FOLDER)
  name = "#{Paths.last_part(real)}-#{CacheFiles.digest(named.bytes).slice(0, 16)}.agcb"
  ok(
    Entry(
      build: site.build,
      folder: folder,
      file: Paths.join(folder, name),
      key: key,
      beside: site.beside,
      libs_dir: site.libs_dir,
      compiler: "",
    ),
  )
end

def read_entry(entry: Entry, settings: Env.Settings) -> Result[Bytes]
  user = try CacheFiles.own_user()
  try CacheFiles.private_kind(entry.build, "directory", user)
  try CacheFiles.private_kind(entry.folder, "directory", user)
  try CacheFiles.private_kind(entry.file, "file", user)
  handle = try File.open(entry.file, "read", CacheFiles.IO_TIMEOUT_MS)
  read = read_whole(handle, entry, settings)
  _ = File.close(handle, CacheFiles.IO_TIMEOUT_MS)
  read
end

def read_whole(handle: File.Handle, entry: Entry, settings: Env.Settings) -> Result[Bytes]
  head = try read_exact(handle, HEAD_BYTES)
  size = try text_size(head)
  bytes = try read_exact(handle, size)
  text = try String.from_bytes(bytes)
  return error("the entry is for another build or program") if !text.start_with?("#{entry.key}\nprogram ")

  # The key has no line feed inside a line, so its lines are the first ones of the text, then the program line.
  lines = text.split("\n").drop(entry.key.split("\n").size)
  try check_lines(settings, lines.drop(1))
  program = try read_rest(handle)
  if lines[0] != "program #{CacheFiles.digest(program)}" or !made_by?(program, settings.version)
    return error("the program of the entry is damaged")
  end

  ok(program)
end

# The length that the head of an entry gives.
def text_size(head: Bytes) -> Result[Int]
  text = try String.from_bytes(head)
  # The length is checked in characters: a head with a multi-byte character is shorter and not an entry.
  if text.length != HEAD_BYTES or !text.start_with?(HEAD_WORD) or !text.end_with?("\n")
    return error("not a cache entry")
  end

  size = try text.slice(HEAD_WORD.length, HEAD_DIGITS).to_i
  return error("the head of the entry is wrong") if size < 0 or size > MAX_TEXT_BYTES

  ok(size)
end

# Every source file must still have the digest the entry holds, and every probe must still answer as it did.
def check_lines(settings: Env.Settings, lines: List[String]) -> Result[Void]
  workspace = settings.workspace
  for line in lines
    if line.start_with?(COMPILER_WORD)
      return error("the C compiler changed") if line != CacheFiles.compiler_line(settings.env.os)
    elsif line.start_with?(SOURCE_WORD)
      try check_source(workspace, line)
    elsif line.start_with?(TREE_WORD)
      try check_tree(workspace, line)
    elsif line.start_with?(ABSENT_WORD)
      path = line.slice(ABSENT_WORD.length, line.length - ABSENT_WORD.length)
      if path.include?(String.from_code(0)) or workspace.file_exists.call(path)
        return error("a place that was empty has a file now")
      end
    elsif line.start_with?(PRESENT_WORD)
      try check_present(workspace, line.slice(PRESENT_WORD.length, line.length - PRESENT_WORD.length))
    else
      return error("a line of the entry is wrong")
    end
  end

  ok()
end

def check_source(workspace: Workspace.Workspace, line: String) -> Result[Void]
  return error("a line of the entry is wrong") if line.length <= SOURCE_WORD.length + DIGEST_CHARS + 1

  wanted = line.slice(SOURCE_WORD.length, DIGEST_CHARS)
  from = SOURCE_WORD.length + DIGEST_CHARS + 1
  path = line.slice(from, line.length - from)
  # A path with a NUL is a contract error of the File calls, which would end the front end.
  return error("a line of the entry is wrong") if path.include?(String.from_code(0))

  read = try workspace.read_bytes.call(path)
  return error("#{path} changed") if CacheFiles.digest(read) != wanted

  ok()
end

def check_tree(workspace: Workspace.Workspace, line: String) -> Result[Void]
  return error("a line of the entry is wrong") if line.length <= TREE_WORD.length + DIGEST_CHARS + 1

  from = TREE_WORD.length + DIGEST_CHARS + 1
  path = line.slice(from, line.length - from)
  return error("a line of the entry is wrong") if path.include?(String.from_code(0))

  if names_digest(workspace, path) != line.slice(TREE_WORD.length, DIGEST_CHARS)
    return error("the native files of #{path} changed")
  end

  ok()
end

# `PATH<TAB>REAL`: the path must still lead to the same file.
def check_present(workspace: Workspace.Workspace, rest: String) -> Result[Void]
  parts = rest.split("\t")
  return error("a line of the entry is wrong") if parts.size != 2 or parts[0].include?(String.from_code(0))

  real = try workspace.real_path.call(parts[0])
  return error("#{parts[0]} leads somewhere else") if real != parts[1]

  ok()
end

# Whether the bytes begin as a program of this version does (the check that an entry of another build, with the same
# size and time, is not run): the magic, and the version text after the format number and the length.
def made_by?(program: Bytes, version: String) -> Bool
  wanted = version.bytes
  return false if program.size < VERSION_AT + wanted.size or program[8] != wanted.size

  magic = String.from_bytes(program.take(MAGIC.length))
  found = String.from_bytes(program.take(VERSION_AT + wanted.size).drop(VERSION_AT))
  magic.ok? and magic.unwrap! == MAGIC and found.ok? and found.unwrap! == version
end

# Exactly `count` bytes, or an error when the file ends first.
def read_exact(handle: File.Handle, count: Int) -> Result[Bytes]
  pieces: List[Bytes] = []
  left = count
  while left > 0
    got = try File.read_bytes(handle, piece(left), CacheFiles.IO_TIMEOUT_MS)
    return error("the entry ends too soon") if got.size == 0

    pieces = pieces.push(got)
    left -= got.size
  end

  ok(Bytes.concat(pieces))
end

def piece(left: Int) -> Int
  return left if left < CacheFiles.PIECE

  CacheFiles.PIECE
end

# The rest of the file, up to the size the VM takes.
def read_rest(handle: File.Handle) -> Result[Bytes]
  pieces: List[Bytes] = []
  total = 0
  finished = false
  while !finished
    got = try File.read_bytes(handle, CacheFiles.PIECE, CacheFiles.IO_TIMEOUT_MS)
    total += got.size
    return error("the program of the entry is too large") if total > MAX_PROGRAM_BYTES

    finished = got.size == 0
    pieces = pieces.push(got)
  end

  ok(Bytes.concat(pieces))
end
