## The lock agentica.lock (docs/future/45-packages.md, 45.6): every package of the graph, direct and transitive, with
## the exact version, the git commit, the hash of its .agc files and the direct dependencies it asks for. A failure is
## PKG-LOCK-INVALID, with the file and the key path (toml_read.agc). This reads one file; project.agc checks it against
## the manifest.

import Toml from "std/toml"
import Manifest from "manifest"
import Semver from "semver"
import Reader from "toml_read"

# The keys of the lock and of a [[package]] table, in the order the lock writes them.
TOP_KEYS = ["version", "package"]
PACKAGE_KEYS = ["name", "version", "source", "commit", "hash", "requires"]

LOCK_FORMAT = 1
HASH_PREFIX = "sha256:"
HEX = Set.new("0123456789abcdef".split(""))

## A direct dependency of a package: the key and the minimum version its own manifest asks for.
export struct Requirement
  key: String
  minimum: String
end

## One locked package. name is its key. hash is `sha256:` and 64 hex digits; commit is the full git commit.
export struct Locked
  name: String
  version: String
  source: String
  commit: String
  hash: String
  requires: List[Requirement]
end

## A read lock. packages are in the order of the file.
export struct Lock
  file: String
  packages: List[Locked]
end

## Reads the lock at file.
export def read(file: String) -> Result[Lock]
  reading = Reader.Reading(file: file, code: "PKG-LOCK-INVALID")
  text = try Reader.read_text(reading)
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
      locked = try package_of(reading, items[index], Reader.item("package", index))
      if seen.include?(locked.name)
        return error(Reader.fail(reading, Reader.child(Reader.item("package", index), "name"), "package locked twice"))
      end
      seen = seen.add(locked.name)
      packages = packages.push(locked)
    end
  end
  return ok(Lock(file: file, packages: packages))
end

## The locked package with this key, or an error.
export def find(lock: Lock, key: String) -> Result[Locked]
  for locked in lock.packages
    if locked.name == key
      return ok(locked)
    end
  end
  return error("#{key} is not in the lock")
end

## The key and minimum of a `key@minimum` text, or what is wrong with it.
export def requirement(text: String) -> Result[Requirement]
  at = text.split("@")
  if at.size != 2
    return error("a requirement is key@minimum")
  end
  problem = Manifest.key_problem(at[0])
  if problem != ""
    return error(problem)
  end
  parsed = Semver.parse(at[1])
  if !parsed.ok?
    return error(parsed.message)
  end
  return ok(Requirement(key: at[0], minimum: at[1]))
end

def package_of(reading: Reader.Reading, value: Toml.Value, path: String) -> Result[Locked]
  entries = try Reader.table(reading, value, path)
  try Reader.known_keys(reading, entries, PACKAGE_KEYS, path)
  for key in PACKAGE_KEYS
    if !entries.has_key?(key)
      return error(Reader.fail(reading, Reader.child(path, key), "missing key"))
    end
  end
  name = try text_of(reading, entries, path, "name")
  if Manifest.key_problem(name) != ""
    return error(
      Reader.fail_help(reading, Reader.child(path, "name"), "not a package key", Manifest.key_problem(name)),
    )
  end
  version = try text_of(reading, entries, path, "version")
  parsed = Semver.parse(version)
  if !parsed.ok?
    return error(Reader.fail_help(reading, Reader.child(path, "version"), "not a version", parsed.message))
  end
  source = try text_of(reading, entries, path, "source")
  if source == ""
    return error(Reader.fail(reading, Reader.child(path, "source"), "the value is empty"))
  end
  commit = try text_of(reading, entries, path, "commit")
  if !hex?(commit) or (commit.length != 40 and commit.length != 64)
    return error(Reader.fail(reading, Reader.child(path, "commit"), "a commit is 40 or 64 lowercase hex digits"))
  end
  hash = try text_of(reading, entries, path, "hash")
  if !hash.starts_with?(HASH_PREFIX) or !hex?(hash.slice(7, hash.length - 7)) or hash.length != 71
    return error(Reader.fail(reading, Reader.child(path, "hash"), "a hash is sha256: and 64 lowercase hex digits"))
  end
  requires = try requires_of(reading, entries["requires"], Reader.child(path, "requires"))
  return ok(
    Locked(name: name, version: version, source: source, commit: commit, hash: hash, requires: requires),
  )
end

def text_of(reading: Reader.Reading, entries: Map[String, Toml.Value], path: String, key: String) -> Result[String]
  return Reader.text(reading, entries[key], Reader.child(path, key))
end

def requires_of(reading: Reader.Reading, value: Toml.Value, path: String) -> Result[List[Requirement]]
  items = try Reader.array(reading, value, path)
  found: List[Requirement] = []
  keys: Set[String] = Set.new([])
  for index in 0...items.size
    at = Reader.item(path, index)
    text = try Reader.text(reading, items[index], at)
    parsed = requirement(text)
    if !parsed.ok?
      return error(Reader.fail_help(reading, at, "not a requirement", parsed.message))
    end
    if keys.include?(parsed.unwrap!.key)
      return error(Reader.fail(reading, at, "package required twice"))
    end
    keys = keys.add(parsed.unwrap!.key)
    found = found.push(parsed.unwrap!)
  end
  return ok(found)
end

def hex?(text: String) -> Bool
  return text != "" and text.split("").all? do |character| HEX.include?(character) end
end
