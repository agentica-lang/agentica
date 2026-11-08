## Builds native modules from their C sources (docs/grammar/05b-modules.md), over the pure rules of
## packages/native_build.agc: the Workspace builder of the commands that run or write a program (app/ turns it on).
##
## The compiler is the user's: the words of `CC` (split at spaces, no shell, no quoting), else `cc` (`gcc` on Windows,
## the MSYS2 UCRT64 toolchain the VM is built with). The manifest names no compiler and no flag: its sources, defines
## and libraries become the arguments of NativeBuild.arguments, passed as a list to Process.spawn_captured, which runs
## no shell, with the package folder as the working folder. agentica_native.h comes from this binary (it carries the
## header of its own VM), so a module always builds against the API that loads it. A fetched package (`pinned`) is
## compiled from a copy instead: the bytes the request carries (checked against its lock row by the core) are written
## to `package/` in the private folder of the build, which is the working folder and holds the sources, and the copy
## is removed before the entry is put in place.
##
## The output is content-addressed in the package cache: `<cache>/native-build/<key>/libNAME.so` (`.dylib`,
## `NAME.dll`), where the key is the SHA-256 of the files of native/, the table, the compiler words, the first lines of
## `--version` and `-dumpmachine`, the header, and the variables that move the compiler's search (CPATH,
## C_INCLUDE_PATH, CPLUS_INCLUDE_PATH, LIBRARY_PATH). System headers, installed libraries and the rest of the
## environment are not in the key; neither is a file outside native/. The files of native/ are hashed again after the
## compile, and a change during it stores nothing. Nothing is written into the package. An entry is made in a new
## private folder beside the others, with the library, its `include/` and a receipt (the SHA-256 of the library), then
## renamed into place in one no-replace step, so a reader never sees half an entry and two builds of one key keep the
## first. A run that finds no entry takes the lock of the key (`<key>.lock` beside it, File.try_lock) and looks again,
## so parallel first runs build once and the others use that entry. The library is code the run loads, so the
## `native-build` folder and an entry are used only when they are this user's and writable by no one else
## (cache_files.agc, private_kind; on Windows only their kind is checked), the library is a regular file in the entry,
## and the receipt matches: anything else is PKG-NATIVE-BUILD, never a silent rebuild over it. Temporary folders that
## a run left (it died during a build) are removed once an hour old.
##
## A compiler that cannot start, fails or leaves no library is PKG-NATIVE-BUILD at the manifest and
## `native.NAME.build`. The plain builder prints the compiler's standard error as it is, and `built native NAME: PATH`
## after a build, on stderr; the quiet one (for `--json` and `--ai`) prints nothing and puts the start of the
## compiler's standard error in the message instead. A builder keeps what it built or failed for the rest of the run
## (an ATS table), so a module that many files use is built, and reported, once. Under a --deny-* flag or --sandbox,
## where the VM refuses native code, nothing is built: `compile` gets the `refusing` builder, the others none (app/).

import Diag from "../diagnostics/diagnostic"
import Paths from "../modules/import_path"
import Failure from "../modules/link_failure"
import Workspace from "../modules/workspace"
import NativeBuild from "../packages/native_build"
import CacheFiles from "cache_files"

# The folder of the package cache that holds the builds, and the names inside an entry.
BUILD_FOLDER = "native-build"
INCLUDE_FOLDER = "include"
# The folder of the private build folder that holds the copy of a fetched package.
COPY_FOLDER = "package"
RECEIPT = "receipt"
# The std/ source name of the header the binary carries (vm/tools/gen-embedded.sh), and its file name.
HEADER = "internal/native/agentica_native.h"
HEADER_NAME = "agentica_native.h"
# Deadlines, in milliseconds: the start of a compiler, a question to it, a whole build, and file work.
START_TIMEOUT_MS = 10_000
QUERY_TIMEOUT_MS = 30_000
BUILD_TIMEOUT_MS = 600_000
FILE_TIMEOUT_MS = 30_000
LOCK_PAUSE_MS = 50
# How long a run waits for the lock of a key: a whole build, then a minute more for its file work.
LOCK_WAIT_MS = BUILD_TIMEOUT_MS + 60_000
TEMP_TRIES = 5
TEMP_MARK = ".tmp-"
STALE_TEMP_SECONDS = 3600
# The most characters of the compiler's standard error that a quiet failure keeps (its start, where the first error
# is).
MAX_SHOWN = 8000
# The variables that change which headers and libraries the compiler finds; their values are in the key.
SEARCH_VARIABLES = ["CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "LIBRARY_PATH"]

# What one run of the compiler gave.
struct Ran
  status: Int
  stdout: String
  stderr: String
end

## A builder for one run: it builds a request, or finds it built, the first time it is asked, and gives the same
## answer for the same library afterwards. `noted` prints on stderr what the compiler says and the path of a new build;
## without it (`--json`, `--ai`) nothing is printed, so stderr holds the diagnostic alone.
export def builder(noted: Bool) -> Fn[Workspace.BuildRequest, Workspace.Built]
  memo: ATS[String, String] = ATS.new()
  return builder_of() do |request: Workspace.BuildRequest| remembered(memo, request, noted) end
end

## The builder of `compile` under `flag` (a --deny-* flag or --sandbox), whose program may not open native code: it
## starts no compiler and fails at the build table, so nothing names a module that was not built.
export def refusing(flag: String) -> Fn[Workspace.BuildRequest, Workspace.Built]
  return builder_of() do |request: Workspace.BuildRequest| refused(request, flag) end
end

# The identity of a function value: a block can only be written as the block of a call.
def builder_of(f: Fn[Workspace.BuildRequest, Workspace.Built]) -> Fn[Workspace.BuildRequest, Workspace.Built]
  return f
end

def refused(request: Workspace.BuildRequest, flag: String) -> Workspace.Built
  message = "#{flag} refuses native code, so the module is not built"
  return Workspace.Built.Failed(fail(request, message, "run without #{flag} to build and use the module"))
end

# The answer kept for the library (`L` and its path, or `F` and the packed failure), else a build.
def remembered(memo: ATS[String, String], request: Workspace.BuildRequest, noted: Bool) -> Workspace.Built
  name = [request.file, request.key, request.root, request.system].join("\n")
  kept = ATS.get(memo, name)
  if kept.ok?
    return answer(kept.unwrap!)
  end

  text = ""
  case attempt(request, noted)
    ok(path) -> text = "L#{path}"
    error(packed) -> text = "F#{packed}"
  end

  ATS.put(memo, name, text)
  return answer(text)
end

def answer(text: String) -> Workspace.Built
  rest = text.slice(1, text.length - 1)
  if text.starts_with?("L")
    return Workspace.Built.Library(rest)
  end

  return Workspace.Built.Failed(rest)
end

def attempt(request: Workspace.BuildRequest, noted: Bool) -> Result[String]
  if request.cache_root == ""
    return error(fail(request, "there is no place for the build cache", "set HOME or XDG_CACHE_HOME"))
  end

  compiler = compiler_words(request.system)
  version = try first_line(request, compiler, "--version")
  target = try first_line(request, compiler, "-dumpmachine")
  header = try header_text(request)
  digests = try key_digests(request)
  lines = [
    NativeBuild.key_text(request, digests),
    "compiler #{compiler.join(" ")}",
    "version #{version}",
    "target #{target}",
    "header #{OpenSSL.Digest.sha256_hexdigest(header.bytes)}",
  ]

  key = lines.concat(search_lines()).join("\n")

  base = Paths.join(request.cache_root, BUILD_FOLDER)
  user = try private_base(request, base)
  sweep(base)
  entry = Paths.join(base, OpenSSL.Digest.sha256_hexdigest(key.bytes))
  name = NativeBuild.output_name(request.library, request.system)
  if File.lstat(entry, FILE_TIMEOUT_MS).ok?
    return verified(request, entry, name, user)
  end

  lock = try locked(request, "#{entry}.lock", user)
  built = ok("")
  if File.lstat(entry, FILE_TIMEOUT_MS).ok?
    built = verified(request, entry, name, user)
  else
    built = compile(request, compiler, header, base, entry, name, user, noted, digests)
  end

  _ = File.close(lock, FILE_TIMEOUT_MS)
  return built
end

# The handle of the lock file of one key, locked: one build of a key runs at a time, and the others wait for it and
# then find its entry. The lock ends when the handle closes or the process dies, so a killed build never leaves it
# held. File.try_lock does not wait, so it is tried again every LOCK_PAUSE_MS for a little longer than a build may take
# (LOCK_WAIT_MS), so a run that starts waiting just after a build began does not give up before that build ends. The
# file is made private like the rest of the cache, or must already be (private_kind): another user that could open it
# could hold its lock and stall every first build.
def locked(request: Workspace.BuildRequest, path: String, user: Int) -> Result[FileHandle]
  help = "remove the file #{path}"
  opened = File.open(path, "create_private", FILE_TIMEOUT_MS)
  if !opened.ok?
    opened = File.open(path, "append", FILE_TIMEOUT_MS)
    if !opened.ok?
      return error(fail(request, "cannot open the lock file #{path}: #{opened.message}", help))
    end

    if !CacheFiles.private_kind(path, "file", user).ok?
      _ = File.close(opened.unwrap!, FILE_TIMEOUT_MS)
      return error(fail(request, "the lock file #{path} is not private to this user", help))
    end
  end

  handle = opened.unwrap!
  deadline = Time.monotonic_ms() + LOCK_WAIT_MS
  while true
    taken = File.try_lock(handle, FILE_TIMEOUT_MS)
    if !taken.ok?
      _ = File.close(handle, FILE_TIMEOUT_MS)
      return error(fail(request, "cannot lock #{path}: #{taken.message}", ""))
    end

    if taken.unwrap!
      return ok(handle)
    end

    if Time.monotonic_ms() > deadline
      _ = File.close(handle, FILE_TIMEOUT_MS)
      return error(fail(request, "another build of this module still holds #{path}", "run again when it ends"))
    end

    Task.sleep(LOCK_PAUSE_MS)
  end

  return error(fail(request, "cannot lock #{path}", ""))
end

# One line of the key for each search variable that is set.
def search_lines() -> List[String]
  lines: List[String] = []
  for variable in SEARCH_VARIABLES
    value = System.env(variable)
    if value.ok?
      lines = lines.push("env #{variable}=#{value.unwrap!}")
    end
  end

  return lines
end

# Removes the temporary folders of builds that died, once they are an hour old. A build is bounded by
# BUILD_TIMEOUT_MS (ten minutes), so only a run suspended (SIGSTOP, a sleeping laptop) for over an hour in the middle
# of a build can lose its folder here; its rename then fails and the build is PKG-NATIVE-BUILD, never a half entry.
def sweep(base: String) -> Void
  names = Dir.list(base, FILE_TIMEOUT_MS)
  if !names.ok?
    return
  end

  now = Time.now_ms() / 1000
  for name in names.unwrap!
    if name.starts_with?(TEMP_MARK)
      path = Paths.join(base, name)
      info = File.lstat(path, FILE_TIMEOUT_MS)
      if info.ok? and info.unwrap!.kind == "directory" and now - info.unwrap!.modified_seconds > STALE_TEMP_SECONDS
        _ = Path.remove(path, FILE_TIMEOUT_MS)
      end
    end
  end
end

# The words of CC, else the system's compiler.
def compiler_words(system: String) -> List[String]
  set = System.env("CC")
  if set.ok?
    words = set.unwrap!.split(" ").filter do |word: String| word != "" end
    if words.size > 0
      return words
    end
  end

  if system == "windows"
    return ["gcc"]
  end

  return ["cc"]
end

# The first line the compiler prints for one question (`--version`, `-dumpmachine`), which names it in the key.
def first_line(request: Workspace.BuildRequest, compiler: List[String], question: String) -> Result[String]
  ran = try run(request, compiler, [question], QUERY_TIMEOUT_MS)
  if ran.status != 0
    message = "the C compiler #{compiler[0]} cannot answer #{question} (status #{ran.status})"
    return error(fail(request, message, "set CC to a C compiler such as cc, gcc or clang"))
  end

  lines = ran.stdout.split("\n")
  return ok(lines[0].strip)
end

# Runs the compiler words with `arguments` in the package folder; standard input is closed at once.
def run(request: Workspace.BuildRequest, compiler: List[String], arguments: List[String], ms: Int) -> Result[Ran]
  words = compiler.drop(1).concat(arguments)
  spawned = Process.spawn_captured(compiler[0], words, request.root, START_TIMEOUT_MS)
  if !spawned.ok?
    message = "cannot start the C compiler #{compiler[0]}: #{spawned.message}"
    help = "install a C compiler, or set CC to one"
    if compiler.size > 1
      help = "CC is split at spaces, with no quoting: name a compiler whose path has no space, then its arguments"
    end

    return error(fail(request, message, help))
  end

  child = spawned.unwrap!
  _ = Process.close_stdin(child, START_TIMEOUT_MS)
  output = Process.output(child, ms)
  if !output.ok?
    Process.close(child)
    return error(fail(request, "the C compiler did not finish: #{output.message}", ""))
  end

  waited = Process.wait(child, START_TIMEOUT_MS)
  Process.close(child)
  if !waited.ok?
    return error(fail(request, "the C compiler did not finish: #{waited.message}", ""))
  end

  out = output.unwrap!
  return ok(Ran(status: waited.unwrap!, stdout: out.stdout, stderr: out.stderr))
end

def header_text(request: Workspace.BuildRequest) -> Result[String]
  case FrontEnd.std_source(HEADER)
    ok(text) -> return ok(text)
    error(_) -> return error(fail(request, "this agentica binary carries no #{HEADER_NAME}", ""))
  end
end

# The SHA-256 of each file of native/, in the order of the request: of the bytes it carries for a fetched package.
def key_digests(request: Workspace.BuildRequest) -> Result[List[String]]
  if request.pinned != ""
    return ok(request.contents.map do |bytes: Bytes| OpenSSL.Digest.sha256_hexdigest(bytes) end)
  end

  return file_digests(request)
end

# The SHA-256 of each file of native/ in the package folder, in the order of the request.
def file_digests(request: Workspace.BuildRequest) -> Result[List[String]]
  found: List[String] = []
  for file in request.files
    case File.sha256(Paths.join(request.root, file), FILE_TIMEOUT_MS)
      ok(digest) -> found = found.push(OpenSSL.Digest.hexencode(digest))
      error(message) -> return error(fail(request, "cannot read #{file}: #{message}", ""))
    end
  end

  return ok(found)
end

# Makes the `native-build` folder private to this user (or checks it) and gives the user id (-1 on Windows).
def private_base(request: Workspace.BuildRequest, base: String) -> Result[Int]
  user = CacheFiles.own_user()
  if !user.ok?
    return error(fail(request, "cannot use the build cache: #{user.message}", ""))
  end

  _ = Dir.mkdir(request.cache_root, FILE_TIMEOUT_MS)
  made = CacheFiles.private_folder(base, user.unwrap!)
  if !made.ok?
    return error(fail(request, "cannot use the build cache: #{made.message}", "remove the folder #{base}"))
  end

  return user
end

# The library of an entry that exists: a regular file (never a link) in a folder private to this user (the compiler
# makes the library with the user's umask, and no one else can reach it through the folder), and the one its receipt
# names.
def verified(request: Workspace.BuildRequest, entry: String, name: String, user: Int) -> Result[String]
  library = Paths.join(entry, name)
  help = "remove the folder #{entry} to build again"
  if !CacheFiles.private_kind(entry, "directory", user).ok? or !regular?(library)
    return error(fail(request, "the build cache entry is not private to this user", help))
  end

  receipt = File.read_text(Paths.join(entry, RECEIPT), FILE_TIMEOUT_MS)
  digest = File.sha256(library, FILE_TIMEOUT_MS)
  if !receipt.ok? or !digest.ok? or receipt.unwrap!.strip != OpenSSL.Digest.hexencode(digest.unwrap!)
    return error(fail(request, "the build cache entry is not the one its receipt names", help))
  end

  return ok(library)
end

def regular?(path: String) -> Bool
  info = File.lstat(path, FILE_TIMEOUT_MS)
  return info.ok? and info.unwrap!.kind == "file"
end

# Builds in a new private folder and renames it into place. A concurrent build of the same key that renamed first is
# kept (and verified), and this one is removed.
def compile(
  request: Workspace.BuildRequest,
  compiler: List[String],
  header: String,
  base: String,
  entry: String,
  name: String,
  user: Int,
  noted: Bool,
  digests: List[String],
) -> Result[String]
  temporary = try make_temp(request, base)
  made = compile_in(request, compiler, header, temporary, name, noted, digests)
  if !made.ok?
    _ = Path.remove(temporary, FILE_TIMEOUT_MS)
    return error(made.message)
  end

  if !Path.rename(temporary, entry, FILE_TIMEOUT_MS).ok?
    _ = Path.remove(temporary, FILE_TIMEOUT_MS)
    return verified(request, entry, name, user)
  end

  library = Paths.join(entry, name)
  if noted
    IO.warn("built native #{request.library}: #{library}")
  end

  return ok(library)
end

# The header, the compiler run and the receipt, all in `folder`.
def compile_in(
  request: Workspace.BuildRequest,
  compiler: List[String],
  header: String,
  folder: String,
  name: String,
  noted: Bool,
  digests: List[String],
) -> Result[Void]
  include = Paths.join(folder, INCLUDE_FOLDER)
  if !Dir.mkdir_private(include, FILE_TIMEOUT_MS).ok?
    return error(fail(request, "cannot write the build cache", ""))
  end

  if !CacheFiles.write_private(Paths.join(include, HEADER_NAME), header.bytes).ok?
    return error(fail(request, "cannot write the build cache", ""))
  end

  output = Paths.join(folder, name)
  source = try source_of(request, folder)
  ran = try run(source, compiler, NativeBuild.arguments(source, include, output), BUILD_TIMEOUT_MS)
  said = in_package(ran.stderr, source.root, request.root)
  if noted and said != ""
    IO.warn(without_line_end(said))
  end

  digest = File.sha256(output, FILE_TIMEOUT_MS)
  if ran.status != 0 or !digest.ok?
    message = "the C compiler failed with status #{ran.status}"
    if ran.status == 0
      message = "the C compiler made no library"
    end

    if !noted and said != ""
      message = "#{message}:\n#{shown(said)}"
    end

    return error(fail(request, message, "fix the C sources, or set CC to another compiler"))
  end

  # A file that changed while the compiler read it is not the one the key names: store nothing. The copy of a fetched
  # package is private, and it is not part of the entry.
  if request.pinned != ""
    if !Path.remove(source.root, FILE_TIMEOUT_MS).ok?
      return error(fail(request, "cannot write the build cache", ""))
    end
  elsif try file_digests(request) != digests
    return error(fail(request, "a file of native/ changed during the build", "run again to build the new files"))
  end

  receipt = CacheFiles.write_private(Paths.join(folder, RECEIPT), OpenSSL.Digest.hexencode(digest.unwrap!).bytes)
  if !receipt.ok?
    return error(fail(request, "cannot write the build cache", ""))
  end

  return ok()
end

# The request to compile: the one given for a package read in place; for a fetched package, the same with its root at
# a private copy in `folder` of the files it carries.
def source_of(request: Workspace.BuildRequest, folder: String) -> Result[Workspace.BuildRequest]
  if request.pinned == ""
    return ok(request)
  end

  root = Paths.join(folder, COPY_FOLDER)
  for made in [root].concat(copy_folders(request.files).map do |inner: String| Paths.join(root, inner) end)
    if !Dir.mkdir_private(made, FILE_TIMEOUT_MS).ok?
      return error(fail(request, "cannot write the build cache", ""))
    end
  end

  for index in 0...request.files.size
    if !CacheFiles.write_private(Paths.join(root, request.files[index]), request.contents[index]).ok?
      return error(fail(request, "cannot write the copy of #{request.files[index]} in the build cache", ""))
    end
  end

  return ok(request.with(root: root))
end

# The folders that hold `files` (relative paths joined by "/"), each once, a folder before those inside it.
def copy_folders(files: List[String]) -> List[String]
  found: List[String] = []
  for file in files
    parts = file.split("/")
    for depth in 1...parts.size
      folder = parts.take(depth).join("/")
      if !found.any? do |seen: String| seen == folder end
        found = found.push(folder)
      end
    end
  end

  return found
end

# What the compiler said, with the folder of the private copy of a fetched package named by the package folder it was
# copied from, so `native/x.c:3:1: error` points at a file the user can open (the copy is removed after the build).
def in_package(text: String, copy: String, root: String) -> String
  if copy == root
    return text
  end

  return text.replace(copy, root)
end

# The start of the compiler's standard error, where its first error is, in at most MAX_SHOWN characters.
def shown(text: String) -> String
  trimmed = text.strip
  if trimmed.length <= MAX_SHOWN
    return trimmed
  end

  return "#{trimmed.slice(0, MAX_SHOWN)}..."
end

# The text as IO.warn prints it: it adds the line feed that ends the compiler's last line.
def without_line_end(text: String) -> String
  if text.ends_with?("\n")
    return text.slice(0, text.length - 1)
  end

  return text
end

# A new private folder in `base` that only this build uses.
def make_temp(request: Workspace.BuildRequest, base: String) -> Result[String]
  failure = "no free name"
  for attempt in 0...TEMP_TRIES
    name = Paths.join(base, ".tmp-#{System.pid()}-#{attempt}-#{Random.int(0, 999999999)}")
    case Dir.mkdir_private(name, FILE_TIMEOUT_MS)
      ok(_) -> return ok(name)
      error(message) -> failure = message
    end
  end

  return error(fail(request, "cannot make a folder in the build cache: #{failure}", ""))
end

def fail(request: Workspace.BuildRequest, message: String, help: String) -> String
  if help == ""
    return Failure.fail_key(request.file, request.key, "PKG-NATIVE-BUILD", message, Diag.Help.NoHelp)
  end

  return Failure.fail_key(request.file, request.key, "PKG-NATIVE-BUILD", message, Failure.hint(help))
end
