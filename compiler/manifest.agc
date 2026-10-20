## The manifest agentica.toml (docs/future/45-packages.md, 45.5): the project's own name and version, its direct
## dependencies with a minimum version each, and the [style] rules. A failure is PKG-MANIFEST-INVALID, with the file
## and the key path (toml_read.agc). Package keys are written `owner/repo`, or `host/owner/repo` for any host but
## GitHub.

import Toml from "std/toml"
import Semver from "semver"
import Reader from "toml_read"

# The keys the manifest knows, and those of [style].
TOP_KEYS = ["name", "version", "dependencies", "style"]
STYLE_KEYS = ["max_line_width"]

# A key segment is made of these characters; a first segment with a dot is a host. A GitHub package has no host.
SEGMENT_CHARACTERS = Set.new("abcdefghijklmnopqrstuvwxyz0123456789._-".split(""))
RESERVED_FIRST = Set.new(["std", "pkg"])

## A direct dependency: the key of the package and the minimum version, as written.
export struct Dependency
  key: String
  minimum: String
end

## A read manifest. name and version are "" when the file has none; max_line_width is 0 when it sets no limit.
export struct Manifest
  file: String
  name: String
  version: String
  dependencies: List[Dependency]
  max_line_width: Int
end

## Reads the manifest at file.
export def read(file: String) -> Result[Manifest]
  reading = Reader.Reading(file: file, code: "PKG-MANIFEST-INVALID")
  text = try Reader.read_text(reading)
  root = try Reader.parse(reading, text)
  try Reader.known_keys(reading, root, TOP_KEYS, "")
  name = try optional_text(reading, root, "name")
  if name != ""
    try check_key(reading, name, "name")
  end
  version = try optional_text(reading, root, "version")
  if version != ""
    try check_version(reading, version, "version")
  end
  dependencies = try dependencies_of(reading, root)
  width = try style_of(reading, root)
  return ok(Manifest(file: file, name: name, version: version, dependencies: dependencies, max_line_width: width))
end

## Why text is not a package key, or "" when it is one. A key is `owner/repo` or `host/owner/repo`; each part is
## lowercase letters, digits and . _ -, is not . or .. and does not start with -; std and pkg cannot start a key; and a
## host has a dot and an owner does not.
export def key_problem(key: String) -> String
  segments = key.split("/")
  if segments.size != 2 and segments.size != 3
    return "a package key is owner/repo, or host/owner/repo"
  end
  for segment in segments
    if segment == "" or segment == "." or segment == ".." or segment.starts_with?("-")
      return "a part of a package key is not empty, ., .. or a name that starts with -"
    end
    if !segment.split("").all? do |character| SEGMENT_CHARACTERS.include?(character) end
      return "a package key holds only lowercase letters, digits and . _ -"
    end
  end
  if RESERVED_FIRST.include?(segments[0])
    return "std and pkg cannot start a package key"
  elsif segments[0] == "github.com"
    return "write owner/repo for a GitHub package"
  elsif segments.size == 3 and !segments[0].contains?(".")
    return "the host of a package key has a dot, as in gitlab.com/owner/repo"
  elsif segments.size == 2 and segments[0].contains?(".")
    return "an owner has no dot: write host/owner/repo for another host"
  end
  return ""
end

## The number of leading parts of an import path that would be a package key: three when the first part has a dot (a
## host), else two.
export def key_parts(first: String) -> Int
  if first.contains?(".")
    return 3
  end
  return 2
end

# A string key that may be missing: "" then.
def optional_text(reading: Reader.Reading, root: Map[String, Toml.Value], key: String) -> Result[String]
  if !root.has_key?(key)
    return ok("")
  end
  value = try Reader.text(reading, root[key], key)
  if value == ""
    return error(Reader.fail(reading, key, "the value is empty"))
  end
  return ok(value)
end

def check_key(reading: Reader.Reading, key: String, path: String) -> Result[Void]
  problem = key_problem(key)
  if problem != ""
    return error(Reader.fail_help(reading, path, "not a package key", problem))
  end
  return ok()
end

def check_version(reading: Reader.Reading, version: String, path: String) -> Result[Void]
  parsed = Semver.parse(version)
  if !parsed.ok?
    return error(Reader.fail_help(reading, path, "not a version", parsed.message))
  end
  return ok()
end

# [dependencies]: a key and a minimum version each, in the order of the file.
def dependencies_of(reading: Reader.Reading, root: Map[String, Toml.Value]) -> Result[List[Dependency]]
  found: List[Dependency] = []
  if !root.has_key?("dependencies")
    return ok(found)
  end
  entries = try Reader.table(reading, root["dependencies"], "dependencies")
  for key in entries.keys
    path = Reader.child("dependencies", key)
    try check_key(reading, key, path)
    minimum = try Reader.text(reading, entries[key], path)
    try check_version(reading, minimum, path)
    found = found.push(Dependency(key: key, minimum: minimum))
  end
  return ok(found)
end

# [style]: today max_line_width, a positive integer. 0 when there is no [style] or no limit.
def style_of(reading: Reader.Reading, root: Map[String, Toml.Value]) -> Result[Int]
  if !root.has_key?("style")
    return ok(0)
  end
  entries = try Reader.table(reading, root["style"], "style")
  try Reader.known_keys(reading, entries, STYLE_KEYS, "style")
  if !entries.has_key?("max_line_width")
    return ok(0)
  end
  width = try Reader.integer(reading, entries["max_line_width"], "style.max_line_width")
  if width < 1
    return error(Reader.fail(reading, "style.max_line_width", "the line width is at least 1"))
  end
  return ok(width)
end
