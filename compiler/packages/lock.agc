## The lock agentica.lock (docs/grammar/05b-modules.md): one entry for each package of the build, by local name,
## flat: the name, the git source (the URL and, when the package is a folder of the repository, its subdir) and its pin
## (a tag or a ref), the exact commit and the hash of its .agc files. A package that is a member of the workspace of
## the project (members.agc) has `workspace = true` in place of the commit and the hash: it is read from its folder,
## so it has neither; so is a package that is a local `path` of the root project's manifest, which has the `path` in
## place of the git source. `override = true` marks a package whose source the root project imposes on the whole tree
## (the packages that ask for another source of that name are not compared). A workspace dependency
## (`finn = { git, tag, workspace = true }`) is locked as the entry `finn`, which has `repository` (the `[workspace]`
## repository of the pin) and no hash and no files, and one entry `finn/subdir` for each member folder: a fetched
## package that is a folder of the repository, whose name is `namespace/subdir` and which deps/ keeps in
## `deps/namespace/subdir/`. A name with a namespace needs the workspace entry of that namespace. A failure is
## PKG-LOCK-INVALID, with the file and the key path (toml_read.agc). This reads one file; project.agc checks it against
## the manifest, and package_import.agc against the manifest of each package it loads. `encode` is the writer
## (docs/grammar/05b-modules.md): the file is the tool's own, so it is written whole.

import Workspace from "../modules/workspace"
import GitSource from "git_source"
import NativeArtifact from "native_artifact"
import Toml from "std/toml"
import Reader from "toml_read"

## One locked package. commit is the full git commit; hash is `sha256:` and 64 hex digits. A workspace member (member
## is true) and a package of a `path` (source.path is not "") have "" for both: their files are the ones in the
## folder. override is true when the root manifest overrides the name. repository is "" except for the entry of a
## workspace dependency, which has a commit and no hash and no files of its own: its members are its namespace.
struct Locked
  name: String
  source: GitSource.Source
  commit: String
  hash: String
  member: Bool
  override: Bool
  repository: String
end

## One locked native artifact: the lock key of the package ("" for the project root), the library and the
## system, with the archive URL, its expected SHA-256 and the member to use. One row is one alias on one system.
struct Artifact
  package: String
  library: String
  system: String
  url: String
  sha256: String
  member: String
end

## A read lock. packages and artifacts are in the order of the file.
struct Lock
  file: String
  packages: List[Locked]
  artifacts: List[Artifact]
end

## Reads the lock at file.
def read(workspace: Workspace.Workspace, file: String) -> Result[Lock]
  reading = Reader.Reading(file: file, code: "PKG-LOCK-INVALID")
  text = try Reader.read_text(workspace, reading)
  root = try Reader.parse(reading, text)
  try Reader.known_keys(reading, root, TOP_KEYS, "")
  return error(Reader.fail(reading, "version", "missing key")) if !root.has_key?("version")

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

    try namespaces_agree(reading, packages)
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

  ok(Lock(file: file, packages: packages, artifacts: artifacts))
end

## The text of a lock with these packages and artifacts: `version = 1`, then one `[[package]]` for each,
## sorted by name, then one `[[native-artifact]]` for each, sorted by (package, library, system), with the keys in
## a fixed order. The same entries always give the same bytes, so a lock that did not change makes no diff, and
## `read` gives back what was written. A lock with no packages and no artifacts is `version = 1` alone.
def encode(packages: List[Locked], artifacts: List[Artifact]) -> String
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
  Toml.encode(root).unwrap!
end

## The part of a lock name before its first `/`, the namespace of `finn/core`; "" for a name with no `/`.
def namespace(name: String) -> String
  at = name.index_of("/")
  return "" if at.none?

  name.slice(0, at.unwrap!)
end

## Whether the entry is the one of a workspace dependency: it has no files, and its members are the entries named
## `name/subdir`.
def root?(locked: Locked) -> Bool = locked.repository != ""

## The folders of the members of the workspace dependency `space`, in the order of the lock.
def members_of(lock: Lock, space: String) -> List[String]
  folders: List[String] = []
  for locked in lock.packages
    if namespace(locked.name) == space and !root?(locked)
      folders = folders.push(locked.source.subdir)
    end
  end

  folders
end

## The lock name of the sibling that a package of a workspace dependency means by a dependency on `source`, or "" when
## it is not one. `owner` is the lock name of the package that asks. A sibling is a dependency on the repository of the
## workspace and on a folder that is one of its members; its own pin plays no part, the pin of the workspace does.
def sibling(lock: Lock, owner: String, source: GitSource.Source) -> String
  space = namespace(owner)
  return "" if space == "" or source.subdir == ""

  found = find(lock, space)
  return "" if !found.ok? or !root?(found.unwrap!)

  return "" if GitSource.identity(found.unwrap!.repository) != GitSource.identity(source.git)

  return "#{space}/#{source.subdir}" if members_of(lock, space).any? do |folder| folder == source.subdir end

  ""
end

## Whether the files of the package are read in place, with no fetch, no cache and no hash: a workspace member or a
## `path`.
def in_place?(locked: Locked) -> Bool = locked.member or GitSource.local?(locked.source)

## The locked package with this name, or an error.
def find(lock: Lock, name: String) -> Result[Locked]
  for locked in lock.packages
    return ok(locked) if locked.name == name
  end

  error("#{name} is not in the lock")
end

## The locked artifact for this package, library and system, or an error. package is "" for the project root.
def find_artifact(lock: Lock, package: String, library: String, system: String) -> Result[Artifact]
  for artifact in lock.artifacts
    return ok(artifact) if artifact.package == package and artifact.library == library and artifact.system == system
  end

  error("#{package} #{library} #{system} is not in the lock")
end

## `name@version` for the messages and the stored names of a package's files: the tag, the first characters of the
## commit, or `workspace` for a member.
def label(locked: Locked) -> String
  return "#{locked.name}@workspace" if locked.member

  return "#{locked.name}@path" if GitSource.local?(locked.source)

  "#{locked.name}@#{GitSource.version_label(locked.source, locked.commit)}"
end

private

# The keys of the lock, of a [[package]] table and of a [[native-artifact]] table.
TOP_KEYS = ["version", "package", "native-artifact"]
PACKAGE_KEYS = ["name", "git", "subdir", "tag", "ref", "commit", "hash", "workspace", "path", "override", "repository"]
GIT_KEYS = ["git", "subdir", "tag", "ref", "commit", "hash", "workspace", "repository"]
ARTIFACT_KEYS = ["package", "library", "system", "url", "sha256", "member"]

LOCK_FORMAT = 1
HASH_PREFIX = "sha256:"
HASH_LENGTH = 71
HEX = Set.new("0123456789abcdef".split(""))

# The keys of a package, in the order of 05b: name, git, subdir (when there is one), tag or ref, then commit and hash,
# or `workspace = true` for a member; name and path for a local folder. `override = true` is last.
def package_table(locked: Locked) -> Toml.Value
  keys = package_keys(locked)
  if locked.override
    keys = keys.put("override", Toml.Value.Bool(true))
  end

  Toml.Value.Table(keys)
end

def package_keys(locked: Locked) -> Map[String, Toml.Value]
  if GitSource.local?(locked.source)
    return {"name": Toml.Value.Str(locked.name), "path": Toml.Value.Str(locked.source.path)}
  end

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
  return keys.put("workspace", Toml.Value.Bool(true)) if locked.member

  if root?(locked)
    return keys.put("commit", Toml.Value.Str(locked.commit)).put("repository", Toml.Value.Str(locked.repository))
  end

  keys.put("commit", Toml.Value.Str(locked.commit)).put("hash", Toml.Value.Str(locked.hash))
end

# Why text is not a lock name, or "": a package name, or a package name and a subdir joined by `/`.
def key_problem(name: String) -> String
  space = namespace(name)
  return GitSource.name_problem(name) if space == ""

  problem = GitSource.name_problem(space)
  return problem if problem != ""

  GitSource.subdir_problem(name.slice(space.length + 1, name.length - space.length - 1))
end

# A name with a namespace needs the entry of a workspace dependency of that name, at the same repository, pin and
# commit, and the folder of such an entry holds only its members, so no other kind of entry has the name of
# a namespace. A namespaced entry is not inside the folder of another (`finn/a` and `finn/a/b`).
def namespaces_agree(reading: Reader.Reading, packages: List[Locked]) -> Result[Void]
  names = Set.new(packages.map do |locked| locked.name end)
  roots: Map[String, Locked] = {}
  for locked in packages
    if root?(locked)
      roots = roots.put(locked.name, locked)
    end
  end

  spaces = Set.new(packages.map do |locked| namespace(locked.name) end)
  for index in 0...packages.size
    locked = packages[index]
    here = Reader.child(Reader.item("package", index), "name")
    space = namespace(locked.name)
    if space == "" and spaces.include?(locked.name) and !root?(locked)
      return error(Reader.fail(reading, here, "the name is the namespace of another package"))
    end

    if space != "" and !agrees?(roots.get(space), locked)
      message = "a namespaced package needs the workspace entry #{space} at the same source and commit"
      return error(Reader.fail(reading, here, message))
    end

    if inside_another?(names, locked.name)
      return error(Reader.fail(reading, here, "the folder is inside the folder of another package"))
    end
  end

  ok()
end

# Whether a folder above the folder of the namespaced `name` is the folder of a package in `names`.
def inside_another?(names: Set[String], name: String) -> Bool
  parts = name.split("/")
  for count in 2...parts.size
    return true if names.include?(parts.take(count).join("/"))
  end

  false
end

def agrees?(found: Optional[Locked], member: Locked) -> Bool
  return false if found.none?

  root = found.unwrap!
  same = GitSource.identity(root.source.git) == GitSource.identity(member.source.git)
  same and GitSource.pin(root.source) == GitSource.pin(member.source) and root.commit == member.commit
end

# The sort key of a native artifact row: one alias on one system of one package.
def sort_key(artifact: Artifact) -> String
  sep = String.from_code(0)
  "#{artifact.package}#{sep}#{artifact.library}#{sep}#{artifact.system}"
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

  Toml.Value.Table(keys)
end

# The identity of a native artifact row: one alias on one system of one package.
def identity(artifact: Artifact) -> String = sort_key(artifact)

def artifact_of(reading: Reader.Reading, value: Toml.Value, path: String) -> Result[Artifact]
  entries = try Reader.table(reading, value, path)
  try Reader.known_keys(reading, entries, ARTIFACT_KEYS, path)
  for key in ARTIFACT_KEYS
    return error(Reader.fail(reading, Reader.child(path, key), "missing key")) if !entries.has_key?(key)
  end

  package = try text_of(reading, entries, path, "package")
  if package != ""
    problem = key_problem(package)
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
    ok(_) -> ok(Artifact(package: package, library: library, system: system, url: url, sha256: sha, member: member))
    error(_) ->
      message = "the member is not a safe relative path"
      error(Reader.fail_help(reading, Reader.child(path, "member"), "not a member", message))
  end
end

def package_of(reading: Reader.Reading, value: Toml.Value, path: String) -> Result[Locked]
  entries = try Reader.table(reading, value, path)
  try Reader.known_keys(reading, entries, PACKAGE_KEYS, path)
  required = ["name", "git", "commit", "hash"]
  if entries.has_key?("workspace")
    required = ["name", "git"]
  elsif entries.has_key?("path")
    required = ["name", "path"]
  elsif entries.has_key?("repository")
    required = ["name", "git", "commit", "repository"]
  end

  for key in required
    return error(Reader.fail(reading, Reader.child(path, key), "missing key")) if !entries.has_key?(key)
  end

  name = try text_of(reading, entries, path, "name")
  problem = key_problem(name)
  return error(Reader.fail_help(reading, Reader.child(path, "name"), "not a package name", problem)) if problem != ""

  nested = namespace(name) != ""
  if nested and (entries.has_key?("path") or entries.has_key?("workspace"))
    message = "a namespaced name is a fetched folder of a repository"
    return error(Reader.fail(reading, Reader.child(path, "name"), message))
  end

  override = try override_of(reading, entries, path)
  return path_of(reading, entries, path, name, override) if entries.has_key?("path")

  source = try source_of(reading, entries, path)
  return member_of(reading, entries, path, name, source, override) if entries.has_key?("workspace")
  return root_of(reading, entries, path, name, source, override) if entries.has_key?("repository")

  if nested and name != "#{namespace(name)}/#{source.subdir}"
    message = "a namespaced name is the namespace, a /, and the subdir of the entry"
    return error(Reader.fail(reading, Reader.child(path, "name"), message))
  end

  commit = try text_of(reading, entries, path, "commit")
  problem = GitSource.commit_problem(commit)
  return error(Reader.fail_help(reading, Reader.child(path, "commit"), "not a commit", problem)) if problem != ""

  if source.ref != "" and !commit.start_with?(source.ref)
    return error(Reader.fail(reading, Reader.child(path, "commit"), "the commit does not start with the ref"))
  end

  hash = try text_of(reading, entries, path, "hash")
  if hash.length != HASH_LENGTH or !hash.start_with?(HASH_PREFIX) or !hex?(hash.slice(HASH_PREFIX.length, 64))
    return error(Reader.fail(reading, Reader.child(path, "hash"), "a hash is sha256: and 64 lowercase hex digits"))
  end

  ok(Locked(name: name, source: source, commit: commit, hash: hash, member: false, override: override, repository: ""))
end

# The entry of a workspace dependency: a git source with no subdir, the commit and the `repository` of the workspace
# table at that commit, and no hash, since its members hold the files.
def root_of(
  reading: Reader.Reading,
  entries: Map[String, Toml.Value],
  path: String,
  name: String,
  source: GitSource.Source,
  override: Bool,
) -> Result[Locked]
  if namespace(name) != ""
    return error(Reader.fail(reading, Reader.child(path, "name"), "a workspace entry has a name with no /"))
  end

  for key in ["subdir", "hash"]
    if entries.has_key?(key)
      return error(Reader.fail(reading, Reader.child(path, key), "a workspace entry has no subdir and no hash"))
    end
  end

  commit = try text_of(reading, entries, path, "commit")
  problem = GitSource.commit_problem(commit)
  return error(Reader.fail_help(reading, Reader.child(path, "commit"), "not a commit", problem)) if problem != ""

  if source.ref != "" and !commit.start_with?(source.ref)
    return error(Reader.fail(reading, Reader.child(path, "commit"), "the commit does not start with the ref"))
  end

  repository = try text_of(reading, entries, path, "repository")
  problem = GitSource.git_problem(repository)
  return error(Reader.fail_help(reading, Reader.child(path, "repository"), "not a git URL", problem)) if problem != ""

  ok(
    Locked(
      name: name,
      source: source,
      commit: commit,
      hash: "",
      member: false,
      override: override,
      repository: repository,
    ),
  )
end

# A workspace member: `workspace = true`, a subdir (the member's folder) and neither a commit nor a hash.
def member_of(
  reading: Reader.Reading,
  entries: Map[String, Toml.Value],
  path: String,
  name: String,
  source: GitSource.Source,
  override: Bool,
) -> Result[Locked]
  here = Reader.child(path, "workspace")
  flag = try Reader.boolean(reading, entries["workspace"], here)
  if !flag
    return error(Reader.fail_help(reading, here, "workspace is true", "leave the key out for a fetched package"))
  end

  if source.subdir == ""
    return error(Reader.fail(reading, Reader.child(path, "subdir"), "a workspace member is a folder: missing key"))
  end

  for key in ["commit", "hash", "repository"]
    if entries.has_key?(key)
      message = "a workspace member has no commit, no hash and no repository"
      return error(Reader.fail(reading, Reader.child(path, key), message))
    end
  end

  ok(Locked(name: name, source: source, commit: "", hash: "", member: true, override: override, repository: ""))
end

# A package that is a local folder: `path` and neither a git source nor a commit and a hash.
def path_of(
  reading: Reader.Reading,
  entries: Map[String, Toml.Value],
  path: String,
  name: String,
  override: Bool,
) -> Result[Locked]
  for key in GIT_KEYS
    if entries.has_key?(key)
      message = "a package of a path has no git source, commit or hash"
      return error(Reader.fail(reading, Reader.child(path, key), message))
    end
  end

  folder = try text_of(reading, entries, path, "path")
  problem = GitSource.path_problem(folder)
  return error(Reader.fail_help(reading, Reader.child(path, "path"), "not a path", problem)) if problem != ""

  source = GitSource.Source(git: "", subdir: "", tag: "", ref: "", path: folder)
  ok(Locked(name: name, source: source, commit: "", hash: "", member: false, override: override, repository: ""))
end

# `override = true`, or false when the key is left out.
def override_of(reading: Reader.Reading, entries: Map[String, Toml.Value], path: String) -> Result[Bool]
  return ok(false) if !entries.has_key?("override")

  here = Reader.child(path, "override")
  flag = try Reader.boolean(reading, entries["override"], here)
  if !flag
    help = "leave the key out for a package that is not overridden"
    return error(Reader.fail_help(reading, here, "override is true", help))
  end

  ok(true)
end

def source_of(reading: Reader.Reading, entries: Map[String, Toml.Value], path: String) -> Result[GitSource.Source]
  git = try text_of(reading, entries, path, "git")
  problem = GitSource.git_problem(git)
  return error(Reader.fail_help(reading, Reader.child(path, "git"), "not a git URL", problem)) if problem != ""

  if entries.has_key?("tag") == entries.has_key?("ref")
    return error(Reader.fail(reading, path, "a package has a tag or a ref: write exactly one of them"))
  end

  subdir = ""
  if entries.has_key?("subdir")
    subdir = try text_of(reading, entries, path, "subdir")
    problem = GitSource.subdir_problem(subdir)
    return error(Reader.fail_help(reading, Reader.child(path, "subdir"), "not a subdir", problem)) if problem != ""
  end

  if entries.has_key?("tag")
    tag = try text_of(reading, entries, path, "tag")
    problem = GitSource.tag_problem(tag)
    return error(Reader.fail_help(reading, Reader.child(path, "tag"), "not a tag", problem)) if problem != ""

    return ok(GitSource.Source(git: git, subdir: subdir, tag: tag, ref: "", path: ""))
  end

  ref = try text_of(reading, entries, path, "ref")
  problem = GitSource.ref_problem(ref)
  return error(Reader.fail_help(reading, Reader.child(path, "ref"), "not a ref", problem)) if problem != ""

  ok(GitSource.Source(git: git, subdir: subdir, tag: "", ref: ref, path: ""))
end

def text_of(reading: Reader.Reading, entries: Map[String, Toml.Value], path: String, key: String) -> Result[String]
  Reader.text(reading, entries[key], Reader.child(path, key))
end

def hex?(text: String) -> Bool = text.split("").all? do |letter| HEX.include?(letter) end
