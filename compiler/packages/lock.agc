## The lock agentica.lock (docs/grammar/05b-modules.md): one entry for each package of the build, by local name,
## flat: the name, the git source and its pin (a tag or a ref), the exact commit and the hash of its .agc files. A
## failure is PKG-LOCK-INVALID, with the file and the key path (toml_read.agc). This reads one file; project.agc checks
## it against the manifest, and package_import.agc against the manifest of each package it loads. `encode` is the
## writer (docs/future/45-packages.md, 45.9): the file is the tool's own, so it is written whole.

import Workspace from "../modules/workspace"
import GitSource from "git_source"
import Toml from "std/toml"
import Reader from "toml_read"

# The keys of the lock and of a [[package]] table. A package has exactly one of tag and ref.
TOP_KEYS = ["version", "package"]
PACKAGE_KEYS = ["name", "git", "tag", "ref", "commit", "hash"]

LOCK_FORMAT = 1
HASH_PREFIX = "sha256:"
HASH_LENGTH = 71
HEX = Set.new("0123456789abcdef".split(""))

## One locked package. commit is the full git commit; hash is `sha256:` and 64 hex digits.
export struct Locked
  name: String
  source: GitSource.Source
  commit: String
  hash: String
end

## A read lock. packages are in the order of the file.
export struct Lock
  file: String
  packages: List[Locked]
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
  return ok(Lock(file: file, packages: packages))
end

## The text of a lock with these packages: `version = 1`, then one `[[package]]` for each, sorted by name, with the
## keys in the order of 05b. The same packages always give the same bytes, so a lock that did not change makes no diff,
## and `read` gives back what was written.
export def encode(packages: List[Locked]) -> String
  sorted = packages.sort_by do |locked| locked.name end
  tables = sorted.map do |locked| package_table(locked) end
  root = Toml.Value.Table({"version": Toml.Value.Int(LOCK_FORMAT), "package": Toml.Value.Array(tables)})
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

# The keys of a package, in the order of 05b: name, git, tag or ref, commit, hash.
def package_table(locked: Locked) -> Toml.Value
  pin = Toml.Value.Str(locked.source.ref)
  pin_key = "ref"
  if locked.source.tag != ""
    pin = Toml.Value.Str(locked.source.tag)
    pin_key = "tag"
  end
  return Toml.Value.Table(
    {
      "name": Toml.Value.Str(locked.name),
      "git": Toml.Value.Str(locked.source.git),
      pin_key: pin,
      "commit": Toml.Value.Str(locked.commit),
      "hash": Toml.Value.Str(locked.hash),
    },
  )
end

def package_of(reading: Reader.Reading, value: Toml.Value, path: String) -> Result[Locked]
  entries = try Reader.table(reading, value, path)
  try Reader.known_keys(reading, entries, PACKAGE_KEYS, path)
  for key in ["name", "git", "commit", "hash"]
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
  return ok(Locked(name: name, source: source, commit: commit, hash: hash))
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
  if entries.has_key?("tag")
    tag = try text_of(reading, entries, path, "tag")
    problem = GitSource.tag_problem(tag)
    if problem != ""
      return error(Reader.fail_help(reading, Reader.child(path, "tag"), "not a tag", problem))
    end
    return ok(GitSource.Source(git: git, tag: tag, ref: ""))
  end
  ref = try text_of(reading, entries, path, "ref")
  problem = GitSource.ref_problem(ref)
  if problem != ""
    return error(Reader.fail_help(reading, Reader.child(path, "ref"), "not a ref", problem))
  end
  return ok(GitSource.Source(git: git, tag: "", ref: ref))
end

def text_of(reading: Reader.Reading, entries: Map[String, Toml.Value], path: String, key: String) -> Result[String]
  return Reader.text(reading, entries[key], Reader.child(path, key))
end

def hex?(text: String) -> Bool
  return text.split("").all? do |letter| HEX.include?(letter) end
end
