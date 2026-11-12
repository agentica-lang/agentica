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

import Declarations from "../modules/declarations"
import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Linker from "../modules/linker"
import Resolve from "../modules/resolve_import"
import Workspace from "../modules/workspace"
import NativeBuild from "../packages/native_build"
import PackageCache from "../packages/package_cache"
import PackageHash from "../packages/package_hash"
import Ast from "../syntax/ast"
import CacheFiles from "cache_files"
import RandomName from "random_name"

# The folder of the entries, in the build folder (io/cache_files.agc).
BYTECODE_FOLDER = "bytecode"

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

# The words that start the lines after the program line, and the digest length in hex.
SOURCE_WORD = "source "
TREE_WORD = "tree "
ABSENT_WORD = "absent "
PRESENT_WORD = "present "
DIGEST_CHARS = 64

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
  Hit(Bytes)
  Miss
end

## The plan for the root file `root` (as typed). `wanted` is false for `--no-cache`. The cache is off for a front end
## that was not started by the binary (no `self_path`, or a stdlib/ folder instead of the embedded std/ sources), for a
## root that cannot be resolved and for a project whose manifest or lock is not good: the front end then says why.
export def plan(settings: Env.Settings, root: String, wanted: Bool) -> Plan
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
export def lookup(plan: Plan, settings: Env.Settings) -> Lookup
  case plan
    Plan.Off -> Lookup.Miss
    Plan.On(entry) ->
      found = read_entry(entry, settings)
      return Lookup.Hit(found.unwrap!) if found.ok?

      Lookup.Miss
  end
end

## Keeps `program`, which was compiled from `modules`, as the entry of the plan. It gives false when it could not (a
## folder that is not safe or not writable); the run goes on either way. The probes are taken here, after the compile,
## so a file that appears between the two is the one gap: it is seen as present, not as absent.
export def store(plan: Plan, settings: Env.Settings, modules: List[Linker.LinkedModule], program: Bytes) -> Bool
  case plan
    Plan.Off -> false
    Plan.On(entry) ->
      sources = modules.filter do |module: Linker.LinkedModule| !Resolve.embedded?(module.key) end
      probes = probe_lines(settings, entry.libs_dir, sources)
      return false if !probes.ok?

      lines = sources.map do |module: Linker.LinkedModule| source_line(module) end
      libraries = library_lines(settings.workspace, sources, built_libraries(settings, sources))
      return false if !libraries.ok?

      lines = lines.concat(libraries.unwrap!)
      text = [entry.key, "program #{CacheFiles.digest(program)}"].concat(lines).concat(probes.unwrap!).join("\n")
      publish(entry, text, program)
  end
end

def source_line(module: Linker.LinkedModule) -> String
  "#{SOURCE_WORD}#{CacheFiles.digest(module.text.bytes)} #{module.key}"
end

# One `source` line for each file that a native library of the program may come from or load (the manifest that names
# it and every file of native/), and one `tree` line for each package folder, with a digest of the names of its native/
# files, so a change or an added file makes the entry miss and the build (which hashes the package against the lock)
# runs again. A path that a `system` list of candidates chose by (module.probed) is not read: it gets the line of an
# import place, so the entry misses when the library appears, goes away or leads elsewhere, and the pick is made again.
def library_lines(
  workspace: Workspace.Workspace,
  modules: List[Linker.LinkedModule],
  built: List[String],
) -> Result[List[String]]
  paths = built
  probed: List[String] = []
  for module in modules
    paths = paths.concat(module.watched)
    probed = probed.concat(module.probed)
  end

  lines: List[String] = []
  for path in probed.uniq
    lines = lines.push(try probe(workspace, path))
  end

  for path in paths.uniq
    return error("the path has a line feed, a tab or a NUL") if !plain?(path)

    if workspace.directory_exists.call(path)
      lines = lines.push("#{TREE_WORD}#{names_digest(workspace, path)} #{path}")
    else
      read = try workspace.read_bytes.call(path)
      lines = lines.push("#{SOURCE_WORD}#{CacheFiles.digest(read)} #{path}")
    end
  end

  ok(lines)
end

# The libraries of the build cache (io/native_build.agc) that the extern functions of the program name: a removed or
# changed build makes the entry miss, so the module is built again.
def built_libraries(settings: Env.Settings, modules: List[Linker.LinkedModule]) -> List[String]
  base = Paths.join(PackageCache.root(settings.env), "native-build/")
  found: List[String] = []
  return found if base == "native-build/"

  for module in modules
    for decl in module.declarations
      case decl
        Ast.Decl.Function(node) ->
          case node.native
            some(native) ->
              if native.library.start_with?(base)
                found = found.push(native.library)
              end

            none -> next
          end

        _ -> next
      end
    end
  end

  found
end

# The digest of the names of the native/ files of a package folder: those the package hash covers, and those the walk
# of a build reads (hidden ones too; a refused walk is its failure), so a new file of either kind is a miss.
def names_digest(workspace: Workspace.Workspace, root: String) -> String
  hashed = PackageHash.native_files(workspace, root).join("\n")
  walked = ""
  case NativeBuild.native_files(workspace, root, "", "")
    ok(paths) -> walked = paths.join("\n")
    error(packed) -> walked = "refused #{packed}"
  end

  CacheFiles.digest("#{hashed}\n\n#{walked}".bytes)
end

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

  # Under a --deny-* flag no module is built (Settings.native_denied), so the program names a library to build by its
  # bare name, which the VM refuses with the rest of the native code: it has an entry of its own, never a plain run's.
  if settings.native_denied
    root = "denied #{root}"
    named = root
  end

  key = [FORMAT, "version #{settings.version}", site.binary, root, site.inputs].join("\n")
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
    ),
  )
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
      if file.start_with?("std/")
        next
      elsif file.start_with?("pkg/")
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

  ok(lines.uniq)
end

# The line for one place. A path with a line feed or a tab would break the lines; it keeps the entry from being made.
def probe(workspace: Workspace.Workspace, path: String) -> Result[String]
  return error("the path has a line feed, a tab or a NUL") if !plain?(path)

  return ok("#{ABSENT_WORD}#{path}") if !workspace.file_exists.call(path)

  real = try workspace.real_path.call(path)
  return error("the path has a line feed, a tab or a NUL") if !plain?(real)

  ok("#{PRESENT_WORD}#{path}\t#{real}")
end

def plain?(path: String) -> Bool
  !path.include?("\n") and !path.include?("\t") and !path.include?(String.from_code(0))
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

def read_whole(handle: FileHandle, entry: Entry, settings: Env.Settings) -> Result[Bytes]
  head = try read_exact(handle, HEAD_BYTES)
  size = try text_size(head)
  bytes = try read_exact(handle, size)
  text = try String.from_bytes(bytes)
  return error("the entry is for another build or program") if !text.start_with?("#{entry.key}\nprogram ")

  # The key has no line feed inside a line, so its lines are the first ones of the text, then the program line.
  lines = text.split("\n").drop(entry.key.split("\n").size)
  try check_lines(settings.workspace, lines.drop(1))
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
def check_lines(workspace: Workspace.Workspace, lines: List[String]) -> Result[Void]
  for line in lines
    if line.start_with?(SOURCE_WORD)
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
def read_exact(handle: FileHandle, count: Int) -> Result[Bytes]
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
def read_rest(handle: FileHandle) -> Result[Bytes]
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

# Writes the entry to a new private file beside its place under a name nobody can guess, and renames it there. A
# rename never replaces (Path.rename), so the old entry is removed first: a reader that comes in between finds none,
# which is a miss, and a run that dies in between leaves no entry. A file system that cannot rename without replacing
# (the rename then fails) never gets an entry; the run is not affected. A `_build/` made by the cache gets a
# .gitignore of its own, so the bytecode is not committed by mistake.
def publish(entry: Entry, text: String, program: Bytes) -> Bool
  return false if !prepare_folder(entry).ok?

  CacheFiles.sweep(entry.folder)
  suffix = RandomName.hex()
  return false if !suffix.ok?

  body = text.bytes
  data = Bytes.concat([head(body.size).bytes, body, program])
  temporary = Paths.join(entry.folder, "#{Paths.last_part(entry.file)}.tmp-#{suffix.unwrap!}")
  CacheFiles.install(temporary, data, entry.file)
end

# Both folders must be ones this program may trust (private_kind), or be made now. The .gitignore goes in `_build/`
# when the cache makes it there.
def prepare_folder(entry: Entry) -> Result[Void]
  user = try CacheFiles.own_user()
  made = try CacheFiles.private_folder(entry.build, user)
  if made and entry.beside
    _ = CacheFiles.write_private(Paths.join(entry.build, ".gitignore"), "*\n".bytes)
  end

  try CacheFiles.private_folder(entry.folder, user)
  ok()
end

def head(size: Int) -> String
  digits = size.to_s
  while digits.length < HEAD_DIGITS
    digits = "0#{digits}"
  end

  "#{HEAD_WORD}#{digits}\n"
end
