## The lock agentica.lock (docs/grammar/05b-modules.md): one entry for each package of the build, by local name,
## flat: the name, the git source (the URL and, when the package is a folder of the repository, its subdir) and its pin
## (a tag or a ref), the exact commit and the hash of its .agc files. A package that is a member of the workspace of
## the project (members.agc) has `workspace = true` in place of the commit and the hash: it is read from its folder,
## so it has neither. A failure is PKG-LOCK-INVALID, with the file and the key path (toml_read.agc). This reads one
## file; project.agc checks it against the manifest, and package_import.agc against the manifest of each package it
## loads. `encode` is the writer (docs/future/45-packages.md, 45.9): the file is the tool's own, so it is written
## whole.

import Workspace from "../modules/workspace"
import GitSource from "git_source"
import NativeArtifact from "native_artifact"
import Toml from "std/toml"
import Reader from "toml_read"

# The keys of the lock, of a [[package]] table and of a [[native-artifact]] table.
TOP_KEYS = ["version", "package", "native-artifact"]
PACKAGE_KEYS = ["name", "git", "subdir", "tag", "ref", "commit", "hash", "workspace"]
ARTIFACT_KEYS = ["package", "library", "system", "url", "sha256", "member"]

LOCK_FORMAT = 1
HASH_PREFIX = "sha256:"
HASH_LENGTH = 71
HEX = Set.new("0123456789abcdef".split(""))

## One locked package. commit is the full git commit; hash is `sha256:` and 64 hex digits. A workspace member (member
## is true) has "" for both: its files are the ones in the member's folder.
export struct Locked
  name: String
  source: GitSource.Source
  commit: String
  hash: String
  member: Bool
end

## One locked native artifact: the lock key of the package ("" for the project root), the library and the
## system, with the archive URL, its expected SHA-256 and the member to use. One row is one alias on one system.
export struct Artifact
  package: String
  library: String
  system: String
  url: String
  sha256: String
  member: String
end

## A read lock. packages and artifacts are in the order of the file.
export struct Lock
  file: String
  packages: List[Locked]
  artifacts: List[Artifact]
end

## Reads the lock at file.
export def read(workspace: Workspace.Workspace, file: String) -> Result[Lock]
  reading = Reader.Reading(file: file, code: "PKG-LOCK-INVALID")
  text = try Reader.read_text(workspace, reading)
  root = try Reader.parse(reading, text)
  try Reader.known_keys(reading, root, TOP_KEYS, "")
  if !root.has_key?("version")
    return error(Reader.fail(reading, "version", "missing key"))
  end

  format = try Reader.integer(reading, root["version"], "version")
  if format != LOCK_FORMAT
    return error(Reader.fail(reading, "version", "this Agentica reads lock format #{LOCK_FORMAT}"))
  end

  packages: List[Locked] = []
  if root.has_key?("package")
    items = try Reader.array(reading, root["package"], "package")
    seen: Set[String] = Set.new([])
    for index in 0...items.size
      path = Reader.item("package", index)
      locked = try package_of(reading, items[index], path)
      if seen.include?(locked.name)
        return error(Reader.fail(reading, Reader.child(path, "name"), "package locked twice"))
      end

      seen = seen.add(locked.name)
      packages = packages.push(locked)
    end
  end

  artifacts: List[Artifact] = []
  if root.has_key?("native-artifact")
    items = try Reader.array(reading, root["native-artifact"], "native-artifact")
    seen: Set[String] = Set.new([])
    for index in 0...items.size
      path = Reader.item("native-artifact", index)
      artifact = try artifact_of(reading, items[index], path)
      key = identity(artifact)
      if seen.include?(key)
        return error(Reader.fail(reading, Reader.child(path, "system"), "native artifact locked twice"))
      end

      seen = seen.add(key)
      artifacts = artifacts.push(artifact)
    end
  end

  return ok(Lock(file: file, packages: packages, artifacts: artifacts))
end

## The text of a lock with these packages and artifacts: `version = 1`, then one `[[package]]` for each,
## sorted by name, then one `[[native-artifact]]` for each, sorted by (package, library, system), with the keys in
## a fixed order. The same entries always give the same bytes, so a lock that did not change makes no diff, and
## `read` gives back what was written. A lock with no packages and no artifacts is `version = 1` alone.
export def encode(packages: List[Locked], artifacts: List[Artifact]) -> String
  sorted = packages.sort_by do |locked| locked.name end
  tables = sorted.map do |locked| package_table(locked) end
  ordered = artifacts.sort_by do |artifact| sort_key(artifact) end
  artifact_tables = ordered.map do |artifact| artifact_table(artifact) end
  root = Toml.Value.Table({"version": Toml.Value.Int(LOCK_FORMAT)})
  if tables.size > 0 and artifact_tables.size > 0
    version = Toml.Value.Int(LOCK_FORMAT)
    root = Toml.Value.Table({
      "version": version,
      "package": Toml.Value.Array(tables),
      "native-artifact": Toml.Value.Array(artifact_tables),
    })
  elsif tables.size > 0
    root = Toml.Value.Table({"version": Toml.Value.Int(LOCK_FORMAT), "package": Toml.Value.Array(tables)})
  elsif artifact_tables.size > 0
    version = Toml.Value.Int(LOCK_FORMAT)
    root = Toml.Value.Table({"version": version, "native-artifact": Toml.Value.Array(artifact_tables)})
  end

  # The keys are fixed and every value is a string or the version, so std/toml has no reason to refuse them.
  return Toml.encode(root).unwrap!
end

## The locked package with this name, or an error.
export def find(lock: Lock, name: String) -> Result[Locked]
  for locked in lock.packages
    if locked.name == name
      return ok(locked)
    end
  end

  return error("#{name} is not in the lock")
end

## The locked artifact for this package, library and system, or an error. package is "" for the project root.
export def find_artifact(lock: Lock, package: String, library: String, system: String) -> Result[Artifact]
  for artifact in lock.artifacts
    if artifact.package == package and artifact.library == library and artifact.system == system
      return ok(artifact)
    end
  end

  return error("#{package} #{library} #{system} is not in the lock")
end

## `name@version` for the messages and the stored names of a package's files: the tag, the first characters of the
## commit, or `workspace` for a member.
export def label(locked: Locked) -> String
  if locked.member
    return "#{locked.name}@workspace"
  end

  return "#{locked.name}@#{GitSource.version_label(locked.source, locked.commit)}"
end

# The keys of a package, in the order of 05b: name, git, subdir (when there is one), tag or ref, then commit and hash,
# or `workspace = true` for a member.
def package_table(locked: Locked) -> Toml.Value
  pin = Toml.Value.Str(locked.source.ref)
  pin_key = "ref"
  if locked.source.tag != ""
    pin = Toml.Value.Str(locked.source.tag)
    pin_key = "tag"
  end

  keys = {"name": Toml.Value.Str(locked.name), "git": Toml.Value.Str(locked.source.git)}
  if locked.source.subdir != ""
    keys = keys.put("subdir", Toml.Value.Str(locked.source.subdir))
  end

  keys = keys.put(pin_key, pin)
  if locked.member
    return Toml.Value.Table(keys.put("workspace", Toml.Value.Bool(true)))
  end

  return Toml.Value.Table(keys.put("commit", Toml.Value.Str(locked.commit)).put("hash", Toml.Value.Str(locked.hash)))
end

# The sort key of a native artifact row: one alias on one system of one package.
def sort_key(artifact: Artifact) -> String
  sep = String.from_code(0)
  return "#{artifact.package}#{sep}#{artifact.library}#{sep}#{artifact.system}"
end

# The keys of a native artifact, in a fixed order: package, library, system, url, sha256, member.
def artifact_table(artifact: Artifact) -> Toml.Value
  keys = {
    "package": Toml.Value.Str(artifact.package),
    "library": Toml.Value.Str(artifact.library),
    "system": Toml.Value.Str(artifact.system),
    "url": Toml.Value.Str(artifact.url),
    "sha256": Toml.Value.Str(artifact.sha256),
    "member": Toml.Value.Str(artifact.member),
  }
  return Toml.Value.Table(keys)
end

# The identity of a native artifact row: one alias on one system of one package.
def identity(artifact: Artifact) -> String
  return sort_key(artifact)
end

def artifact_of(reading: Reader.Reading, value: Toml.Value, path: String) -> Result[Artifact]
  entries = try Reader.table(reading, value, path)
  try Reader.known_keys(reading, entries, ARTIFACT_KEYS, path)
  for key in ARTIFACT_KEYS
    if !entries.has_key?(key)
      return error(Reader.fail(reading, Reader.child(path, key), "missing key"))
    end
  end

  package = try text_of(reading, entries, path, "package")
  if package != ""
    problem = GitSource.name_problem(package)
    if problem != ""
      return error(Reader.fail_help(reading, Reader.child(path, "package"), "not a package name", problem))
    end
  end

  library = try text_of(reading, entries, path, "library")
  problem = GitSource.name_problem(library)
  if problem != ""
    return error(Reader.fail_help(reading, Reader.child(path, "library"), "not a library name", problem))
  end

  system = try text_of(reading, entries, path, "system")
  if system != "linux" and system != "macos" and system != "windows"
    here = Reader.child(path, "system")
    return error(Reader.fail_help(reading, here, "not a system", "write linux, macos or windows"))
  end

  url = try text_of(reading, entries, path, "url")
  if !NativeArtifact.url_allowed?(url)
    message = "the url is not an https URL (or an http URL to 127.0.0.1 or [::1])"
    return error(Reader.fail_help(reading, Reader.child(path, "url"), "not a download URL", message))
  end

  sha = try text_of(reading, entries, path, "sha256")
  if !NativeArtifact.valid_sha?(sha)
    message = "the sha256 is not 64 lowercase hex digits"
    return error(Reader.fail_help(reading, Reader.child(path, "sha256"), "not a sha256", message))
  end

  member = try text_of(reading, entries, path, "member")
  case NativeArtifact.canonical_member(member)
    ok(_) ->
      return ok(Artifact(package: package, library: library, system: system, url: url, sha256: sha, member: member))
    error(_) ->
      message = "the member is not a safe relative path"
      return error(Reader.fail_help(reading, Reader.child(path, "member"), "not a member", message))
  end
end

def package_of(reading: Reader.Reading, value: Toml.Value, path: String) -> Result[Locked]
  entries = try Reader.table(reading, value, path)
  try Reader.known_keys(reading, entries, PACKAGE_KEYS, path)
  required = ["name", "git", "commit", "hash"]
  if entries.has_key?("workspace")
    required = ["name", "git"]
  end

  for key in required
    if !entries.has_key?(key)
      return error(Reader.fail(reading, Reader.child(path, key), "missing key"))
    end
  end

  name = try text_of(reading, entries, path, "name")
  problem = GitSource.name_problem(name)
  if problem != ""
    return error(Reader.fail_help(reading, Reader.child(path, "name"), "not a package name", problem))
  end

  source = try source_of(reading, entries, path)
  if entries.has_key?("workspace")
    return member_of(reading, entries, path, name, source)
  end

  commit = try text_of(reading, entries, path, "commit")
  problem = GitSource.commit_problem(commit)
  if problem != ""
    return error(Reader.fail_help(reading, Reader.child(path, "commit"), "not a commit", problem))
  end

  if source.ref != "" and !commit.starts_with?(source.ref)
    return error(Reader.fail(reading, Reader.child(path, "commit"), "the commit does not start with the ref"))
  end

  hash = try text_of(reading, entries, path, "hash")
  if hash.length != HASH_LENGTH or !hash.starts_with?(HASH_PREFIX) or !hex?(hash.slice(HASH_PREFIX.length, 64))
    return error(Reader.fail(reading, Reader.child(path, "hash"), "a hash is sha256: and 64 lowercase hex digits"))
  end

  return ok(Locked(name: name, source: source, commit: commit, hash: hash, member: false))
end

# A workspace member: `workspace = true`, a subdir (the member's folder) and neither a commit nor a hash.
def member_of(
  reading: Reader.Reading,
  entries: Map[String, Toml.Value],
  path: String,
  name: String,
  source: GitSource.Source,
) -> Result[Locked]
  here = Reader.child(path, "workspace")
  flag = try Reader.boolean(reading, entries["workspace"], here)
  if !flag
    return error(Reader.fail_help(reading, here, "workspace is true", "leave the key out for a fetched package"))
  end

  if source.subdir == ""
    return error(Reader.fail(reading, Reader.child(path, "subdir"), "a workspace member is a folder: missing key"))
  end

  for key in ["commit", "hash"]
    if entries.has_key?(key)
      return error(Reader.fail(reading, Reader.child(path, key), "a workspace member has no commit and no hash"))
    end
  end

  return ok(Locked(name: name, source: source, commit: "", hash: "", member: true))
end

def source_of(reading: Reader.Reading, entries: Map[String, Toml.Value], path: String) -> Result[GitSource.Source]
  git = try text_of(reading, entries, path, "git")
  problem = GitSource.git_problem(git)
  if problem != ""
    return error(Reader.fail_help(reading, Reader.child(path, "git"), "not a git URL", problem))
  end

  if entries.has_key?("tag") == entries.has_key?("ref")
    return error(Reader.fail(reading, path, "a package has a tag or a ref: write exactly one of them"))
  end

  subdir = ""
  if entries.has_key?("subdir")
    subdir = try text_of(reading, entries, path, "subdir")
    problem = GitSource.subdir_problem(subdir)
    if problem != ""
      return error(Reader.fail_help(reading, Reader.child(path, "subdir"), "not a subdir", problem))
    end
  end

  if entries.has_key?("tag")
    tag = try text_of(reading, entries, path, "tag")
    problem = GitSource.tag_problem(tag)
    if problem != ""
      return error(Reader.fail_help(reading, Reader.child(path, "tag"), "not a tag", problem))
    end

    return ok(GitSource.Source(git: git, subdir: subdir, tag: tag, ref: ""))
  end

  ref = try text_of(reading, entries, path, "ref")
  problem = GitSource.ref_problem(ref)
  if problem != ""
    return error(Reader.fail_help(reading, Reader.child(path, "ref"), "not a ref", problem))
  end

  return ok(GitSource.Source(git: git, subdir: subdir, tag: "", ref: ref))
end

def text_of(reading: Reader.Reading, entries: Map[String, Toml.Value], path: String, key: String) -> Result[String]
  return Reader.text(reading, entries[key], Reader.child(path, key))
end

def hex?(text: String) -> Bool
  return text.split("").all? do |letter| HEX.include?(letter) end
end
