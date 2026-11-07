## Source builds of native modules (docs/grammar/05b-modules.md): the `build` key of `[native.NAME]`, which a package
## read in place (the root project, a workspace member, a `path` dependency) compiles with the system C compiler. A
## fetched package never builds: it uses its system entry. This holds the pure parts: the checks of the table, the
## request the machine gets (io/native_build.agc runs the compiler), the compiler arguments of each system and the text
## the build key covers.
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

## The `build` table of a library: the sources (paths in native/, as written), the defines (`NAME` or `NAME=VALUE`)
## and the libraries to link (`m` for `-lm`), in the order of the file.
export struct Build
  sources: List[String]
  defines: List[String]
  libs: List[String]
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
  return ok(Build(sources: sources, defines: defines, libs: libs))
end

## The request for the build of `library` from the package folder `root` (a real path), for the system `os`. Its
## files are not listed yet: `listed` does that when a file first uses the library, so an unused one costs nothing.
export def request(
  library: String,
  build: Build,
  root: String,
  os: String,
  file: String,
  cache_root: String,
) -> Workspace.BuildRequest
  return Workspace.BuildRequest(
    cache_root: cache_root,
    library: library,
    system: os,
    file: file,
    key: Reader.child(Reader.child("native", library), "build"),
    root: root,
    sources: build.sources,
    defines: build.defines,
    libs: build.libs,
    files: [],
  )
end

## The request with the files of its native/ folder, every source among them. A source that is not is
## PKG-NATIVE-MISSING at its item (`native.NAME.build.sources[0]`); a link, a pipe or a device in native/, or more than
## 4096 files or 1024 folders, is PKG-NATIVE-BUILD at `native.NAME.build`.
export def listed(workspace: Workspace.Workspace, request: Workspace.BuildRequest) -> Result[Workspace.BuildRequest]
  files = try native_files(workspace, request.root, request.file, request.key)
  for index in 0...request.sources.size
    source = request.sources[index]
    if !files.any? do |found: String| found == source end
      at = Reader.item(Reader.child(request.key, "sources"), index)
      message = "the source #{source} is not a file of the package"
      help = Failure.hint("put the file in native/")
      return error(Failure.fail_key(request.file, at, "PKG-NATIVE-MISSING", message, help))
    end
  end

  return ok(request.with(files: files))
end

## The file name of the built library of `name` on `system`, as the VM opens it.
export def output_name(name: String, system: String) -> String
  if system == "windows"
    return "#{name}.dll"
  elsif system == "macos"
    return "lib#{name}.dylib"
  end

  return "lib#{name}.so"
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
  return found.concat(request.libs.map do |lib: String| "-l#{lib}" end)
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

  return lines.join("\n")
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
  if !top.ok?
    return error(refused(file, key, "cannot list the package folder: #{top.message}"))
  end

  present = false
  for entry in top.unwrap!
    if PackageHash.fold(entry.name) == NATIVE_FOLDER
      case entry.kind
        Workspace.EntryKind.Directory -> present = present or entry.name == NATIVE_FOLDER
        _ -> return error(refused(file, key, "#{entry.name} is not a folder of the package"))
      end
    end
  end

  if !present
    return ok(found)
  end

  pending = [NATIVE_FOLDER]
  folders = 0
  while pending.size > 0
    folder = pending[pending.size - 1]
    pending = pending.take(pending.size - 1)
    entries = workspace.list_folder.call(Paths.join(root, folder))
    if !entries.ok?
      return error(refused(file, key, "cannot list #{folder}: #{entries.message}"))
    end

    for entry in entries.unwrap!
      path = Paths.join(folder, entry.name)
      case entry.kind
        Workspace.EntryKind.Directory ->
          pending = pending.push(path)
          folders += 1

        Workspace.EntryKind.File -> found = found.push(path)
        Workspace.EntryKind.Link -> return error(refused(file, key, "#{path} is a symbolic link"))
        Workspace.EntryKind.Other -> return error(refused(file, key, "#{path} is not a regular file"))
      end

      if found.size > MAX_FILES or folders > MAX_FOLDERS
        return error(refused(file, key, "native/ holds more than #{MAX_FILES} files or #{MAX_FOLDERS} folders"))
      end
    end
  end

  return ok(found.sort)
end

def refused(file: String, key: String, message: String) -> String
  help = Failure.hint("native/ of a package that builds holds only regular files and folders")
  return Failure.fail_key(file, key, "PKG-NATIVE-BUILD", message, help)
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
  if !entries.has_key?(name)
    return ok(found)
  end

  here = Reader.child(path, name)
  items = try Reader.array(reading, entries[name], here)
  if items.size > limit
    return error(Reader.fail_help(reading, here, "too many items", "write at most #{limit}"))
  end

  for index in 0...items.size
    at = Reader.item(here, index)
    word = try Reader.text(reading, items[index], at)
    why = problem.call(word)
    if why != ""
      return error(Reader.fail_help(reading, at, "not a #{name.slice(0, name.length - 1)}", why))
    end

    found = found.push(word)
  end

  return ok(found)
end

# A C file of native/, in plain folder names (the rules of a subdir), so the hash and the walk cover it.
def source_problem(source: String) -> String
  problem = GitSource.subdir_problem(source)
  if problem != ""
    return problem
  end

  if !source.starts_with?("#{NATIVE_FOLDER}/") or !source.ends_with?(".c")
    return "a source is a .c file in the #{NATIVE_FOLDER}/ folder of the package"
  end

  if source.split("/").any? do |part: String| PackageHash.native_junk?(part) end
    return "a source is not a hidden file, Thumbs.db or desktop.ini"
  end

  return ""
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

  if parts.size == 1
    return ""
  end

  value = define.slice(name.length + 1, define.length - name.length - 1)
  if value.length > MAX_VALUE or !value.split("").all? do |letter: String| WORD_CHARACTERS.include?(letter) end
    return "the value of a define holds only letters, digits and _ . + - (at most #{MAX_VALUE} characters)"
  end

  return ""
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

  return ""
end
