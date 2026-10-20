## The manifest agentica.toml (docs/grammar/05b-modules.md): the project's own name, its direct dependencies and
## the [style] rules. A dependency is a local name and a git source: `sqlite = { git = "https://host/owner/repo", tag =
## "v1.2.0" }`, with exactly one of `tag` and `ref`. A failure is PKG-MANIFEST-INVALID, with the file and the key path
## (toml_read.agc).

import Toml from "std/toml"
import GitSource from "git_source"
import Reader from "toml_read"
import Workspace from "../modules/workspace"

# The keys the manifest knows, and those of [style] and of a dependency.
TOP_KEYS = ["name", "dependencies", "style"]
STYLE_KEYS = ["max_line_width"]
DEPENDENCY_KEYS = ["git", "tag", "ref"]

## A direct dependency: the local name (the segment after `pkg/` in an import) and where it comes from.
export struct Dependency
  name: String
  source: GitSource.Source
end

## A read manifest. name is "" when the file has none; max_line_width is 0 when it sets no limit.
export struct Manifest
  file: String
  name: String
  dependencies: List[Dependency]
  max_line_width: Int
end

## Reads the manifest at file.
export def read(workspace: Workspace.Workspace, file: String) -> Result[Manifest]
  reading = Reader.Reading(file: file, code: "PKG-MANIFEST-INVALID")
  text = try Reader.read_text(workspace, reading)
  root = try Reader.parse(reading, text)
  try Reader.known_keys(reading, root, TOP_KEYS, "")
  name = try optional_name(reading, root)
  dependencies = try dependencies_of(reading, root)
  width = try style_of(reading, root)
  return ok(Manifest(file: file, name: name, dependencies: dependencies, max_line_width: width))
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
    source = try source_of(reading, entries[name], path)
    found = found.push(Dependency(name: name, source: source))
  end
  return ok(found)
end

# One dependency: `git` and exactly one of `tag` and `ref`; any other key, such as a path or a branch, is refused.
def source_of(reading: Reader.Reading, value: Toml.Value, path: String) -> Result[GitSource.Source]
  entries = try Reader.table(reading, value, path)
  try Reader.known_keys(reading, entries, DEPENDENCY_KEYS, path)
  if !entries.has_key?("git")
    return error(Reader.fail_help(reading, path, "missing key git", "only git sources exist: git = \"https://...\""))
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
  return ok(GitSource.Source(git: git, tag: tag, ref: ref))
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
