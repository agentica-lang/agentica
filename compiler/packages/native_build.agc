## Source builds of native modules (docs/grammar/05b-modules.md): the `build` key of `[native.NAME]`, which the system
## C compiler compiles for the root project, a workspace member, a `path` dependency and a fetched package whose
## content the lock pins. This holds the pure parts: the checks of the table, the request the machine gets
## (io/native_build.agc runs the compiler), the pin check of a fetched package, the compiler arguments of each system
## and the text the build key covers.
##
## A fetched package is never compiled in its folder of deps/. When a file first uses its library, every file its hash
## covers is read once (`listed`) and the bytes are checked against the hash of its lock row; the machine then writes
## the files of native/ among them into a private folder of the build and compiles that copy. So what is compiled is
## the code of the locked commit, which the lock lets the user review: a file of native/ that the hash leaves out (a
## dotfile, Thumbs.db) is not copied, a file outside native/ (`#include "../x.h"`) is not there, and a change in deps/
## after the check does not reach the compiler. The compiler and the flags stay the user's. The load of the package
## hashed the folder already, so a link reads the files twice; the second read is what the copy is made of. The hash
## is in the request (`pinned`), so a later prebuilt library can be matched to it.
##
## What a manifest can put on the command line is closed: the sources are files of the package's native/ folder (plain
## folder names, as a `subdir`, ending in `.c`, and found as regular files when the folder is walked, never through a
## link), so each argument is an absolute path inside the package; a define is a C name with an optional value of
## letters, digits and `_ . + -`, given as one `-DNAME=VALUE` argument; a library is a name of the same letters, given
## as one `-lNAME` argument. No argument starts with `@` (a response file) and none can be split: the machine passes
## them as a list, with no shell. The compiler and the flags are not the manifest's: the compiler is the user's (`CC`),
## and the flags are the ones of `arguments` below.

import Paths from "../modules/import_path"
import Failure from "../modules/link_failure"
import Workspace from "../modules/workspace"
import GitSource from "git_source"
import PackageHash from "package_hash"
import Toml from "std/toml"
import Reader from "toml_read"

BUILD_KEYS = ["sources", "defines", "libs"]
# The folder of the package that holds the sources (the one of `file` entries).
NATIVE_FOLDER = "native"
MAX_SOURCES = 256
MAX_DEFINES = 64
MAX_LIBS = 32
MAX_NAME = 128
MAX_VALUE = 256
# The most files and folders the walk of native/ takes; the build key reads each file.
MAX_FILES = 4096
MAX_FOLDERS = 1024
# The first letter of a define and the others; a value and a library name.
DEFINE_FIRST = Set.new("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_".split(""))
DEFINE_REST = Set.new("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_".split(""))
WORD_CHARACTERS = Set.new("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.+-".split(""))
# The first line of the build key; change it when the key or the flags change, so no old build is reused.
KEY_FORMAT = "agentica-native-build-1"
# The helps of a native/ that a build cannot read safely.
UNLISTED = "make the folder readable by this user"
LINKED = "put the file itself in native/, not a link to it"
SPECIAL = "remove the pipe, socket or device from native/"

## The `build` table of a library: the sources (paths in native/, as written), the defines (`NAME` or `NAME=VALUE`)
## and the libraries to link (`m` for `-lm`), in the order of the file.
export struct Build
  sources: List[String]
  defines: List[String]
  libs: List[String]
end

# The files of native/ that a fetched package builds from and their checked bytes, at the same index.
struct Pinned
  files: List[String]
  contents: List[Bytes]
end

## Reads `build = { sources = [...], defines = [...], libs = [...] }` at `path` (`native.NAME.build`). `sources` is
## required (1 to 256), the others are optional; a failure is the reading's code at the key path of the item.
export def parse(reading: Reader.Reading, value: Toml.Value, path: String) -> Result[Build]
  entries = try Reader.table(reading, value, path)
  try Reader.known_keys(reading, entries, BUILD_KEYS, path)
  if !entries.has_key?("sources")
    return error(Reader.fail_help(reading, path, "missing key sources", "list the C files in native/ to compile"))
  end

  sources = try words(reading, entries, path, "sources", MAX_SOURCES, &source_problem)
  if sources.size == 0
    return error(Reader.fail_help(reading, Reader.child(path, "sources"), "no sources", "list at least one C file"))
  end

  defines = try words(reading, entries, path, "defines", MAX_DEFINES, &define_problem)
  libs = try words(reading, entries, path, "libs", MAX_LIBS, &lib_problem)
  ok(Build(sources: sources, defines: defines, libs: libs))
end

## The request for the build of `library` from the package folder `root` (a real path), for the system `os`. `pinned`
## is the locked hash of a fetched package, "" for one read in place; `optional` is the library's `optional` key. Its
## files are not listed yet: `listed` does that when a file first uses the library, so an unused one costs nothing.
export def request(
  library: String,
  build: Build,
  root: String,
  os: String,
  file: String,
  cache_root: String,
  pinned: String,
  optional: Bool,
) -> Workspace.BuildRequest
  Workspace.BuildRequest(
    cache_root: cache_root,
    library: library,
    system: os,
    file: file,
    key: Reader.child(Reader.child("native", library), "build"),
    root: root,
    pinned: pinned,
    optional: optional,
    sources: build.sources,
    defines: build.defines,
    libs: build.libs,
    files: [],
    contents: [],
  )
end

## The request with the files of its native/ folder, every source among them. A source that is not is
## PKG-NATIVE-MISSING at its item (`native.NAME.build.sources[0]`); a link, a pipe or a device in native/, or more than
## 4096 files or 1024 folders, is PKG-NATIVE-BUILD at `native.NAME.build`. A fetched package (`pinned`) has instead
## the files of native/ that its hash covers, with their bytes (pinned_files): a package that cannot be read is
## PKG-NATIVE-BUILD there, and one whose bytes are not the locked ones is PKG-HASH-MISMATCH.
export def listed(workspace: Workspace.Workspace, request: Workspace.BuildRequest) -> Result[Workspace.BuildRequest]
  pinned = try pinned_files(workspace, request)
  files = pinned.files
  if request.pinned == ""
    files = try native_files(workspace, request.root, request.file, request.key)
  end

  for index in 0...request.sources.size
    source = request.sources[index]
    if !files.any? do |found: String| found == source end
      at = Reader.item(Reader.child(request.key, "sources"), index)
      message = "the source #{source} is not a file of the package"
      help = Failure.hint("put the file in native/")
      return error(Failure.fail_key(request.file, at, "PKG-NATIVE-MISSING", message, help))
    end
  end

  ok(request.with(files: files, contents: pinned.contents))
end

## The library that an optional module which could not be built stands for: a folder path, ending in `/`, which no
## loader opens as a library, so a call of the module fails as for a missing library and Native.load gives an error.
## It is `native-build/unbuilt/` in the build cache, which nothing makes, and whose libraries the bytecode cache reads
## before it stores a program: one it cannot read stores none, so the next run tries the build again. With no cache
## (no HOME), it is the package's native/ folder, which holds the sources.
export def unbuilt_path(request: Workspace.BuildRequest) -> String
  base = Paths.join(request.root, NATIVE_FOLDER)
  if request.cache_root != ""
    base = Paths.join(Paths.join(request.cache_root, "native-build"), "unbuilt")
  end

  "#{base}/"
end

## The file name of the built library of `name` on `system`, as the VM opens it.
export def output_name(name: String, system: String) -> String
  if system == "windows"
    return "#{name}.dll"
  elsif system == "macos"
    return "lib#{name}.dylib"
  end

  "lib#{name}.so"
end

## The arguments of the compiler, after its own words: the flags every build gets, those of the system, the output, the
## sources (absolute paths in the package) and the libraries. `include` is the folder that holds agentica_native.h.
## A module links nothing of `agentica` (the VM passes it a table), so an undefined symbol is an error at link time on
## Linux (`-z defs`) and macOS (the default of its linker, which warns that `-undefined error` is deprecated).
export def arguments(request: Workspace.BuildRequest, include: String, output: String) -> List[String]
  found = ["-std=c11", "-O2", "-fvisibility=hidden", "-I#{include}"]
  found = found.concat(request.defines.map do |define: String| "-D#{define}" end)
  if request.system == "windows"
    found = found.concat(["-shared", "-static-libgcc"])
  elsif request.system == "macos"
    install_name = "-Wl,-install_name,@rpath/#{output_name(request.library, "macos")}"
    found = found.concat(["-dynamiclib", install_name])
  else
    found = found.concat(["-fPIC", "-shared", "-Wl,-z,defs"])
  end

  found = found.concat(["-o", output])
  found = found.concat(request.sources.map do |source: String| Paths.join(request.root, source) end)
  found.concat(request.libs.map do |lib: String| "-l#{lib}" end)
end

## The text the build key covers, from the request: the format, the library, the system, the table as written and
## `digests`, the SHA-256 (hex) of each file of `request.files` in the same order. The machine adds the compiler, its
## version and target, and the header the binary carries, then hashes the whole.
export def key_text(request: Workspace.BuildRequest, digests: List[String]) -> String
  lines = [KEY_FORMAT, "library #{request.library}", "system #{request.system}"]
  lines = lines.concat(request.sources.map do |source: String| "source #{source}" end)
  lines = lines.concat(request.defines.map do |define: String| "define #{define}" end)
  lines = lines.concat(request.libs.map do |lib: String| "lib #{lib}" end)
  for index in 0...request.files.size
    lines = lines.push("file #{digests[index]} #{request.files[index]}")
  end

  lines.join("\n")
end

## Every file of native/ below `root` (relative paths, in bytewise order), hidden ones included, since a source may
## include any of them. Only that folder is walked, with an explicit stack, and never through a link: native/ itself
## must be a real folder (a link or a file in its place, in any case of the name, is refused), and a link, a pipe or a
## device anywhere in it is refused. A package with no native/ has no files.
export def native_files(
  workspace: Workspace.Workspace,
  root: String,
  file: String,
  key: String,
) -> Result[List[String]]
  found: List[String] = []
  top = workspace.list_folder.call(root)
  return error(refused(file, key, "cannot list the package folder: #{top.message}", UNLISTED)) if !top.ok?

  present = false
  for entry in top.unwrap!
    if PackageHash.fold(entry.name) == NATIVE_FOLDER
      case entry.kind
        Workspace.EntryKind.Directory -> present = present or entry.name == NATIVE_FOLDER
        _ -> return error(refused(file, key, "#{entry.name} is not a folder of the package", "make native a folder"))
      end
    end
  end

  return ok(found) if !present

  pending = [NATIVE_FOLDER]
  folders = 0
  while pending.size > 0
    folder = pending[pending.size - 1]
    pending = pending.take(pending.size - 1)
    entries = workspace.list_folder.call(Paths.join(root, folder))
    return error(refused(file, key, "cannot list #{folder}: #{entries.message}", UNLISTED)) if !entries.ok?

    for entry in entries.unwrap!
      path = Paths.join(folder, entry.name)
      case entry.kind
        Workspace.EntryKind.Directory ->
          pending = pending.push(path)
          folders += 1

        Workspace.EntryKind.File -> found = found.push(path)
        Workspace.EntryKind.Link -> return error(refused(file, key, "#{path} is a symbolic link", LINKED))
        Workspace.EntryKind.Other -> return error(refused(file, key, "#{path} is not a regular file", SPECIAL))
      end

      if found.size > MAX_FILES or folders > MAX_FOLDERS
        message = "native/ holds more than #{MAX_FILES} files or #{MAX_FOLDERS} folders"
        return error(refused(file, key, message, "keep fewer files in native/"))
      end
    end
  end

  ok(found.sort)
end

# The files of native/ that the hash of a fetched package covers and their bytes, once all the bytes the hash covers
# are read and match the pin; none for a package read in place.
def pinned_files(workspace: Workspace.Workspace, request: Workspace.BuildRequest) -> Result[Pinned]
  empty = Pinned(files: [], contents: [])
  return ok(empty) if request.pinned == ""

  paths: List[String] = []
  case PackageHash.covered_files(workspace, request.root)
    PackageHash.Listing.Files(found) -> paths = found
    PackageHash.Listing.Stopped(reason) -> return error(unreadable(request, reason))
  end

  # A fetch copies no file over PackageHash.MAX_FILE_BYTES, nor more than PackageHash.MAX_TOTAL_BYTES in all: a
  # folder of deps/ that holds more was changed, and is read no further than one byte past the limit.
  contents: List[Bytes] = []
  total = 0
  for path in paths
    read = workspace.read_prefix.call(Paths.join(request.root, path), PackageHash.MAX_FILE_BYTES + 1)
    return error(unreadable(request, PackageHash.Hashed.Unreadable("#{path}: #{read.message}"))) if !read.ok?

    total += read.unwrap!.size
    if read.unwrap!.size > PackageHash.MAX_FILE_BYTES or total > PackageHash.MAX_TOTAL_BYTES
      limits = "#{PackageHash.MAX_FILE_BYTES} bytes a file and #{PackageHash.MAX_TOTAL_BYTES} in all"
      message = "the files of the package are over the limits of a fetched package (#{limits}), at #{path}"
      return error(refused(request.file, request.key, message, "run agentica install to put the locked files back"))
    end

    contents = contents.push(read.unwrap!)
  end

  if PackageHash.stream_hash(paths, contents) != request.pinned
    message = "the files of the package are not the ones agentica.lock pins, so its module is not built"
    help = Failure.hint("run agentica install to put the locked files back")
    return error(Failure.fail_key(request.file, request.key, "PKG-HASH-MISMATCH", message, help))
  end

  found = empty
  for index in 0...paths.size
    if PackageHash.native_path?(paths[index])
      found = found.with(files: found.files.push(paths[index]), contents: found.contents.push(contents[index]))
    end
  end

  ok(found)
end

# A fetched package whose covered files cannot be listed or read.
def unreadable(request: Workspace.BuildRequest, reason: PackageHash.Hashed) -> String
  message = ""
  case reason
    PackageHash.Hashed.Link(path) -> message = "#{path} in the package is a symbolic link"
    PackageHash.Hashed.Unreadable(why) -> message = "cannot read the package: #{why}"
    PackageHash.Hashed.Hash(_) -> message = "cannot read the package"
  end

  refused(request.file, request.key, message, "run agentica install to put the locked files back")
end

def refused(file: String, key: String, message: String, help: String) -> String
  Failure.fail_key(file, key, "PKG-NATIVE-BUILD", message, Failure.hint(help))
end

# The strings of the optional list `name` of the table: at most `limit`, each one passing `problem` ("" when fine).
def words(
  reading: Reader.Reading,
  entries: Map[String, Toml.Value],
  path: String,
  name: String,
  limit: Int,
  problem: Fn[String, String],
) -> Result[List[String]]
  found: List[String] = []
  return ok(found) if !entries.has_key?(name)

  here = Reader.child(path, name)
  items = try Reader.array(reading, entries[name], here)
  return error(Reader.fail_help(reading, here, "too many items", "write at most #{limit}")) if items.size > limit

  for index in 0...items.size
    at = Reader.item(here, index)
    word = try Reader.text(reading, items[index], at)
    why = problem.call(word)
    return error(Reader.fail_help(reading, at, "not a #{name.slice(0, name.length - 1)}", why)) if why != ""

    found = found.push(word)
  end

  ok(found)
end

# A C file of native/, in plain folder names (the rules of a subdir), so the hash and the walk cover it.
def source_problem(source: String) -> String
  problem = GitSource.subdir_problem(source)
  return problem if problem != ""

  if !source.starts_with?("#{NATIVE_FOLDER}/") or !source.ends_with?(".c")
    return "a source is a .c file in the #{NATIVE_FOLDER}/ folder of the package"
  end

  if source.split("/").any? do |part: String| PackageHash.native_junk?(part) end
    return "a source is not a hidden file, Thumbs.db or desktop.ini"
  end

  ""
end

# `NAME` or `NAME=VALUE`: a C name, and a value of letters, digits and `_ . + -`.
def define_problem(define: String) -> String
  parts = define.split("=")
  name = parts[0]
  letters = name.split("")
  if letters.size == 0 or letters.size > MAX_NAME or !DEFINE_FIRST.include?(letters[0])
    return "a define starts with a C name (a letter or _, at most #{MAX_NAME} characters)"
  end

  if !letters.all? do |letter: String| DEFINE_REST.include?(letter) end
    return "the name of a define holds only letters, digits and _"
  end

  return "" if parts.size == 1

  value = define.slice(name.length + 1, define.length - name.length - 1)
  if value.length > MAX_VALUE or !value.split("").all? do |letter: String| WORD_CHARACTERS.include?(letter) end
    return "the value of a define holds only letters, digits and _ . + - (at most #{MAX_VALUE} characters)"
  end

  ""
end

# A library name for `-l`: letters, digits and `_ . + -`, not starting with `-`.
def lib_problem(lib: String) -> String
  letters = lib.split("")
  if letters.size == 0 or letters.size > MAX_NAME or letters[0] == "-"
    return "a library is a name such as m or sqlite3 (1 to #{MAX_NAME} characters, not starting with -)"
  end

  if !letters.all? do |letter: String| WORD_CHARACTERS.include?(letter) end
    return "a library name holds only letters, digits and _ . + -"
  end

  ""
end
