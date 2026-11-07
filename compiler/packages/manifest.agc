## The manifest agentica.toml (docs/grammar/05b-modules.md): the project's own name, its direct dependencies, the
## native libraries of a package ([native]) and the [style] rules. A dependency is a local name and a git source:
## `sqlite = { git = "https://host/owner/repo", tag = "v1.2.0" }`, with exactly one of `tag` and `ref`, and an optional
## `subdir`: the folder of the repository that is the package. The root project's manifest may also write
## `name = { path = "../x" }` (a folder on this machine, read in place) and `override = true` (its source wins over any
## other source of the name in the tree); `require_package` refuses both in the manifest of a package. A failure is
## PKG-MANIFEST-INVALID, with the file and the key path (toml_read.agc). The `[workspace]` table is known here but read
## by members.agc, and only for the project's manifest: the manifest of a package skips it. `[native]` is the other way
## round: only a package's is used.

import Workspace from "../modules/workspace"
import Paths from "../modules/import_path"
import GitSource from "git_source"
import NativeArtifact from "native_artifact"
import NativeBuild from "native_build"
import PackageHash from "package_hash"
import Toml from "std/toml"
import Reader from "toml_read"

# The keys the manifest knows, and those of [style] and of a dependency.
TOP_KEYS = ["name", "dependencies", "native", "style", "workspace"]
STYLE_KEYS = ["max_line_width", "blank_line_after_end"]
DEPENDENCY_KEYS = ["git", "tag", "ref", "subdir", "path", "override"]
GIT_KEYS = ["git", "tag", "ref", "subdir"]
PLACE_KEYS = ["file", "system", "url", "sha256", "member"]
# The systems a native library can be named for. The key is the whole system: a macOS file is a universal binary.
SYSTEMS = Set.new(["linux", "macos", "windows"])
# The folder of a package that holds its native files (package_hash.agc hashes them with the .agc files).
NATIVE_FOLDER = "native"
# The key of [native.NAME] that is not a system: the C sources of the library (native_build.agc).
BUILD_KEY = "build"
MAX_SYSTEM_NAME = 128
MAX_SYSTEM_PATH = 1024
# The most candidates a `system` list holds: each one is looked up on disk when the library is used.
MAX_CANDIDATES = 16

## A direct dependency: the local name (the segment after `pkg/` in an import) and where it comes from. override is
## true when the manifest says `override = true`.
export struct Dependency
  name: String
  source: GitSource.Source
  override: Bool
end

## Where a native library is on one system: `file`, a path inside the package's native/ folder, `system`, one or more
## candidates (names for the system loader or absolute paths, in order of preference, as written), or a downloaded
## artifact (`url`, `sha256` and `member`). Exactly one shape is present: `file` and `system` keep their meaning, and
## a downloaded row names the archive URL, its expected SHA-256 (64 lowercase hex digits) and the member to use from
## it. The other fields are "" (names is empty) when the shape does not use them.
export struct Place
  system: String
  file: String
  names: List[String]
  url: String
  sha256: String
  member: String
end

## A native library of a package: the name its `extern "name"` uses, where it is on each system it names, and the
## `build` table that compiles it from the package's C sources (native_build.agc), if any.
export struct NativeLibrary
  name: String
  places: List[Place]
  build: Optional[NativeBuild.Build]
end

## A read manifest. name is "" when the file has none; max_line_width is 0 when it sets no limit;
## blank_line_after_end is false unless `[style]` turns the rule on.
export struct Manifest
  file: String
  name: String
  dependencies: List[Dependency]
  natives: List[NativeLibrary]
  max_line_width: Int
  blank_line_after_end: Bool
end

# The values of [style]: what the project asks of its files.
struct Style
  max_line_width: Int
  blank_line_after_end: Bool
end

## Reads the manifest at file.
export def read(workspace: Workspace.Workspace, file: String) -> Result[Manifest]
  reading = Reader.Reading(file: file, code: "PKG-MANIFEST-INVALID")
  text = try Reader.read_text(workspace, reading)
  return parse(file, text)
end

## Reads the manifest text, which is said to come from file. The writer checks the text it is about to save with this.
export def parse(file: String, text: String) -> Result[Manifest]
  reading = Reader.Reading(file: file, code: "PKG-MANIFEST-INVALID")
  root = try Reader.parse(reading, text)
  try Reader.known_keys(reading, root, TOP_KEYS, "")
  name = try optional_name(reading, root)
  dependencies = try dependencies_of(reading, root)
  natives = try natives_of(reading, root)
  style = try style_of(reading, root)
  return ok(
    Manifest(
      file: file,
      name: name,
      dependencies: dependencies,
      natives: natives,
      max_line_width: style.max_line_width,
      blank_line_after_end: style.blank_line_after_end,
    ),
  )
end

## Refuses what only the root project's manifest may say, in the manifest of a package (fetched, or a workspace member
## read in place): a `path` dependency, which cannot be published, and `override = true`, which the packages of a tree
## cannot impose on each other. A failure is PKG-ROOT-ONLY at `dependencies.<name>.path` or `.override`.
export def require_package(manifest: Manifest) -> Result[Void]
  reading = Reader.Reading(file: manifest.file, code: "PKG-ROOT-ONLY")
  for dependency in manifest.dependencies
    here = Reader.child("dependencies", dependency.name)
    if GitSource.local?(dependency.source)
      help = "a package is published, so it names git sources; the root project can name a path"
      return error(Reader.fail_help(reading, Reader.child(here, "path"), "only the root project has a path", help))
    end

    if dependency.override
      help = "write override = true in the agentica.toml of the root project"
      return error(Reader.fail_help(reading, Reader.child(here, "override"), "only the root project overrides", help))
    end
  end

  return ok()
end

## The dependency with this name, or an error.
export def find(manifest: Manifest, name: String) -> Result[Dependency]
  for dependency in manifest.dependencies
    if dependency.name == name
      return ok(dependency)
    end
  end

  return error("#{name} is not a dependency")
end

## The local names of the dependencies, in the order of the file.
export def names(manifest: Manifest) -> List[String]
  return manifest.dependencies.map do |dependency| dependency.name end
end

## Whether the manifest declares a downloaded native artifact on any system: a `[native]` row with
## `url`+`sha256`+`member`. Such a project needs a lock even with no dependencies.
export def has_downloaded(manifest: Manifest) -> Bool
  for library in manifest.natives
    for place in library.places
      if place.url != ""
        return true
      end
    end
  end

  return false
end

# The project's own name, a package name too. "" when the file has none.
def optional_name(reading: Reader.Reading, root: Map[String, Toml.Value]) -> Result[String]
  if !root.has_key?("name")
    return ok("")
  end

  name = try Reader.text(reading, root["name"], "name")
  problem = GitSource.name_problem(name)
  if problem != ""
    return error(Reader.fail_help(reading, "name", "not a package name", problem))
  end

  return ok(name)
end

# [dependencies]: a name and an inline table each, in the order of the file.
def dependencies_of(reading: Reader.Reading, root: Map[String, Toml.Value]) -> Result[List[Dependency]]
  found: List[Dependency] = []
  if !root.has_key?("dependencies")
    return ok(found)
  end

  entries = try Reader.table(reading, root["dependencies"], "dependencies")
  for name in entries.keys
    path = Reader.child("dependencies", name)
    problem = GitSource.name_problem(name)
    if problem != ""
      return error(Reader.fail_help(reading, path, "not a package name", problem))
    end

    dependency = try dependency_of(reading, name, entries[name], path)
    found = found.push(dependency)
  end

  return ok(found)
end

# One dependency: a git source (`git`, exactly one of `tag` and `ref`, and an optional `subdir`) or a `path`, and an
# optional `override`; any other key, such as a branch, is refused.
def dependency_of(reading: Reader.Reading, name: String, value: Toml.Value, path: String) -> Result[Dependency]
  entries = try Reader.table(reading, value, path)
  try Reader.known_keys(reading, entries, DEPENDENCY_KEYS, path)
  override = false
  if entries.has_key?("override")
    override = try Reader.boolean(reading, entries["override"], Reader.child(path, "override"))
  end

  if entries.has_key?("path")
    source = try path_source_of(reading, entries, path)
    return ok(Dependency(name: name, source: source, override: override))
  end

  source = try git_source_of(reading, entries, path)
  return ok(Dependency(name: name, source: source, override: override))
end

# A dependency that is a folder on this machine: `path` and nothing of a git source.
def path_source_of(reading: Reader.Reading, entries: Map[String, Toml.Value], path: String) -> Result[GitSource.Source]
  for key in GIT_KEYS
    if entries.has_key?(key)
      help = "write a path alone, or git with a tag or a ref"
      return error(Reader.fail_help(reading, path, "a dependency has a git source or a path", help))
    end
  end

  here = Reader.child(path, "path")
  folder = try Reader.text(reading, entries["path"], here)
  problem = GitSource.path_problem(folder)
  if problem != ""
    return error(Reader.fail_help(reading, here, "not a path", problem))
  end

  return ok(GitSource.Source(git: "", subdir: "", tag: "", ref: "", path: folder))
end

# A dependency that is a git source.
def git_source_of(reading: Reader.Reading, entries: Map[String, Toml.Value], path: String) -> Result[GitSource.Source]
  if !entries.has_key?("git")
    help = "write git = \"https://...\" with a tag or a ref, or path = \"../folder\""
    return error(Reader.fail_help(reading, path, "missing key git", help))
  end

  git = try Reader.text(reading, entries["git"], Reader.child(path, "git"))
  problem = GitSource.git_problem(git)
  if problem != ""
    return error(Reader.fail_help(reading, Reader.child(path, "git"), "not a git URL", problem))
  end

  if entries.has_key?("tag") == entries.has_key?("ref")
    return error(Reader.fail_help(reading, path, "a dependency has a tag or a ref", "write exactly one of them"))
  end

  tag = ""
  ref = ""
  if entries.has_key?("tag")
    tag = try Reader.text(reading, entries["tag"], Reader.child(path, "tag"))
    tag_problem = GitSource.tag_problem(tag)
    if tag_problem != ""
      return error(Reader.fail_help(reading, Reader.child(path, "tag"), "not a tag", tag_problem))
    end
  else
    ref = try Reader.text(reading, entries["ref"], Reader.child(path, "ref"))
    ref_problem = GitSource.ref_problem(ref)
    if ref_problem != ""
      return error(Reader.fail_help(reading, Reader.child(path, "ref"), "not a ref", ref_problem))
    end
  end

  subdir = ""
  if entries.has_key?("subdir")
    subdir = try Reader.text(reading, entries["subdir"], Reader.child(path, "subdir"))
    subdir_problem = GitSource.subdir_problem(subdir)
    if subdir_problem != ""
      return error(Reader.fail_help(reading, Reader.child(path, "subdir"), "not a subdir", subdir_problem))
    end
  end

  return ok(GitSource.Source(git: git, subdir: subdir, tag: tag, ref: ref, path: ""))
end

# [native.NAME]: for each library a table of systems, each with `file`, `system` or a download, and an optional
# `build`.
def natives_of(reading: Reader.Reading, root: Map[String, Toml.Value]) -> Result[List[NativeLibrary]]
  found: List[NativeLibrary] = []
  if !root.has_key?("native")
    return ok(found)
  end

  entries = try Reader.table(reading, root["native"], "native")
  for name in entries.keys
    path = Reader.child("native", name)
    problem = GitSource.name_problem(name)
    if problem != ""
      return error(Reader.fail_help(reading, path, "not a library name", problem))
    end

    systems = try Reader.table(reading, entries[name], path)
    places: List[Place] = []
    build: Optional[NativeBuild.Build] = none
    for system in systems.keys
      here = Reader.child(path, system)
      if system == BUILD_KEY
        build = some(try NativeBuild.parse(reading, systems[system], here))
        next
      end

      if !SYSTEMS.include?(system)
        return error(Reader.fail_help(reading, here, "not a system", "write linux, macos, windows or build"))
      end

      places = places.push(try place_of(reading, system, systems[system], here))
    end

    found = found.push(NativeLibrary(name: name, places: places, build: build))
  end

  return ok(found)
end

# One system of a library: exactly one of `file`, `system`, or the downloaded triple
# `url`+`sha256`+`member` (all three, and neither file nor system with them).
def place_of(reading: Reader.Reading, system: String, value: Toml.Value, path: String) -> Result[Place]
  entries = try Reader.table(reading, value, path)
  try Reader.known_keys(reading, entries, PLACE_KEYS, path)
  downloaded = entries.has_key?("url") or entries.has_key?("sha256") or entries.has_key?("member")
  if downloaded
    if entries.has_key?("file") or entries.has_key?("system")
      help = "write exactly one of them"
      return error(Reader.fail_help(reading, path, "a library has a file, a system name or a download", help))
    end

    for key in ["url", "sha256", "member"]
      if !entries.has_key?(key)
        help = "write all three of them"
        return error(Reader.fail_help(reading, path, "a download has a url, a sha256 and a member", help))
      end
    end

    url = try Reader.text(reading, entries["url"], Reader.child(path, "url"))
    if !NativeArtifact.url_allowed?(url)
      message = "the url is not an https URL (or an http URL to 127.0.0.1 or [::1])"
      return error(Reader.fail_help(reading, Reader.child(path, "url"), "not a download URL", message))
    end

    sha = try Reader.text(reading, entries["sha256"], Reader.child(path, "sha256"))
    if !NativeArtifact.valid_sha?(sha)
      message = "the sha256 is not 64 lowercase hex digits"
      return error(Reader.fail_help(reading, Reader.child(path, "sha256"), "not a sha256", message))
    end

    member = try Reader.text(reading, entries["member"], Reader.child(path, "member"))
    case NativeArtifact.canonical_member(member)
      ok(_) -> return ok(Place(system: system, file: "", names: [], url: url, sha256: sha, member: member))
      error(_) ->
        message = "the member is not a safe relative path"
        return error(Reader.fail_help(reading, Reader.child(path, "member"), "not a member", message))
    end
  end

  if entries.has_key?("file") == entries.has_key?("system")
    return error(Reader.fail_help(reading, path, "a library has a file or a system name", "write exactly one of them"))
  end

  if entries.has_key?("file")
    file = try Reader.text(reading, entries["file"], Reader.child(path, "file"))
    problem = file_problem(file)
    if problem != ""
      return error(Reader.fail_help(reading, Reader.child(path, "file"), "not a native file", problem))
    end

    return ok(Place(system: system, file: file, names: [], url: "", sha256: "", member: ""))
  end

  names = try system_names(reading, entries["system"], Reader.child(path, "system"))
  return ok(Place(system: system, file: "", names: names, url: "", sha256: "", member: ""))
end

# `system`: a name or an absolute path, or a list of them (1 to MAX_CANDIDATES), kept as written. A failure in a list
# is at the key path of its item (`native.libpq.macos.system[1]`).
def system_names(reading: Reader.Reading, value: Toml.Value, path: String) -> Result[List[String]]
  case value
    Toml.Value.Array(items) ->
      if items.size == 0 or items.size > MAX_CANDIDATES
        help = "write between 1 and #{MAX_CANDIDATES} names or absolute paths"
        return error(Reader.fail_help(reading, path, "not a list of library candidates", help))
      end

      names: List[String] = []
      for index in 0...items.size
        names = names.push(try system_name(reading, items[index], Reader.item(path, index)))
      end

      return ok(names)
    _ ->
      name = try system_name(reading, value, path)
      return ok([name])
  end
end

def system_name(reading: Reader.Reading, value: Toml.Value, path: String) -> Result[String]
  name = try Reader.text(reading, value, path)
  problem = system_problem(name)
  if problem != ""
    return error(Reader.fail_help(reading, path, "not a library name", problem))
  end

  return ok(name)
end

# A file of the native/ folder, in plain folder names (the rules of a subdir), so the hash covers it.
def file_problem(file: String) -> String
  problem = GitSource.subdir_problem(file)
  if problem != ""
    return problem
  end

  if !file.starts_with?("#{NATIVE_FOLDER}/")
    return "a native file is a path in the #{NATIVE_FOLDER}/ folder of the package"
  end

  # The hash and the copy leave these names out, so a library there would run unchecked.
  if file.split("/").any? do |part: String| PackageHash.native_junk?(part) end
    return "a native file is not Thumbs.db or desktop.ini, which the package leaves out"
  end

  return ""
end

# A candidate is an absolute path (of any system: the manifest reads the same on every machine, so a Windows path is
# fine in a linux entry and is just never found there) or a name for the system loader, which has no folder in it (the
# rule of `extern "name"`). A relative path would depend on the working directory, which is never searched.
def system_problem(name: String) -> String
  has_nul = name.split("").any? do |char: String| String.code(char) < 32 or String.code(char) == 127 end
  if Paths.rooted?(name)
    if name.length > MAX_SYSTEM_PATH or has_nul
      return "a system library path has no control character and at most #{MAX_SYSTEM_PATH} characters"
    end

    return ""
  end

  bad = name.contains?("/") or name.contains?("\\") or name.contains?(":") or has_nul
  if name.length == 0 or name.length > MAX_SYSTEM_NAME or bad
    return (
      "a system library is a name such as libz.so.1 (no / \\ or :, at most #{MAX_SYSTEM_NAME} characters) " +
      "or an absolute path such as /usr/lib/libz.so"
    )
  end

  return ""
end

# [style]: `max_line_width`, a positive integer (0 when there is none), and `blank_line_after_end`, a boolean (false
# when there is none). Both are off when there is no [style].
def style_of(reading: Reader.Reading, root: Map[String, Toml.Value]) -> Result[Style]
  style = Style(max_line_width: 0, blank_line_after_end: false)
  if !root.has_key?("style")
    return ok(style)
  end

  entries = try Reader.table(reading, root["style"], "style")
  try Reader.known_keys(reading, entries, STYLE_KEYS, "style")
  if entries.has_key?("max_line_width")
    width = try Reader.integer(reading, entries["max_line_width"], "style.max_line_width")
    if width < 1
      return error(Reader.fail(reading, "style.max_line_width", "the line width is at least 1"))
    end

    style = style.with(max_line_width: width)
  end

  if entries.has_key?("blank_line_after_end")
    on = try Reader.boolean(reading, entries["blank_line_after_end"], "style.blank_line_after_end")
    style = style.with(blank_line_after_end: on)
  end

  return ok(style)
end
