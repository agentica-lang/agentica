## Finding the test files of a BDD run: the files named on the command line, and the `.feature` and `_test.agc` files
## under the folders named there. Problems come back as entries too, so the report
## shows them next to the files that run.

import {IO_TIMEOUT} from "bdd_files"

# The manifest of a project, and the folder beside it that holds its installed packages.
MANIFEST_FILE = "agentica.toml"
DEPS_FOLDER = "deps"

## One feature file or test file, or one problem of the search, as the runner reads it (stdlib/test/runner.agc,
## `Entry`): `problem` is "" for a file to run; `kind` is "tests", "feature" or "" (neither); `bytecode`, `source_root`
## and `front_end` are filled in by the driver for a test file.
export struct Entry
  path: String
  problem: String
  kind: String
  bytecode: String
  source_root: String
  front_end: String
end

# What the walk has found so far: the problems in the order they were met, and the files to run.
struct Found
  problems: List[Entry]
  files: List[String]
end

## The kind of a path by its name: "tests" for `_test.agc`, "feature" for `.feature`, else "".
export def kind_of(path: String) -> String
  if path.ends_with?("_test.agc")
    return "tests"
  elsif path.ends_with?(".feature")
    return "feature"
  end
  return ""
end

## The entries for the given paths: first the problems in the order they were met, then the files sorted by path, each
## once. A path is made absolute without following links. A folder is searched for the files whose names fit, in every
## folder below it, except the `deps/` of a project (a folder that holds an `agentica.toml`): those are packages
## installed for the build, not tests of the project. A link to a folder is skipped. A path to a file is taken
## whatever its name is.
export def discover(given: List[String]) -> List[Entry]
  found = Found(problems: [], files: [])
  for text in given
    path = Path.resolve(text).unwrap_or(text)
    info = File.stat(path, IO_TIMEOUT)
    if info.ok? and info.unwrap!.kind == "directory"
      found = walk(path, found)
    elsif info.ok?
      found = Found(problems: found.problems, files: found.files.push(path))
    else
      found = problem(found, path, "test path does not exist")
    end
  end
  entries = found.problems
  previous = ""
  for path in found.files.sort
    if path != previous
      entries = entries.push(entry(path, ""))
    end
    previous = path
  end
  return entries
end

def entry(path: String, problem: String) -> Entry
  return Entry(path: path, problem: problem, kind: kind_of(path), bytecode: "", source_root: "", front_end: "")
end

def problem(found: Found, path: String, message: String) -> Found
  return Found(problems: found.problems.push(entry(path, message)), files: found.files)
end

def walk(directory: String, found: Found) -> Found
  names = Dir.list(directory, IO_TIMEOUT)
  if !names.ok?
    return problem(found, directory, "cannot list the directory: #{names.message}")
  end
  after = found
  # The folder `deps/` beside an agentica.toml is the project's installed packages.
  project = names.unwrap!.any? do |name| name == MANIFEST_FILE end
  for name in names.unwrap!
    after = visit(Path.join([directory, name]).unwrap_or("#{directory}/#{name}"), name, project, after)
  end
  return after
end

# Dir.list decodes a name with a byte that is not UTF-8 as U+FFFD, and no path can be made from that name, so such a
# name is taken for "not UTF-8" even when the file really has a U+FFFD in its name (the only wrong report). Its kind is
# unknown, so it is a problem only when its name fits (a file) and a folder with such a name is skipped.
def visit(path: String, name: String, project: Bool, found: Found) -> Found
  bad_name = name.contains?(String.from_code(65_533))
  info = File.lstat(path, IO_TIMEOUT)
  if !info.ok? and bad_name
    if kind_of(name) != ""
      return problem(found, path, "the file name is not valid UTF-8")
    end
    return found
  elsif !info.ok?
    return problem(found, path, "cannot read the file information: #{info.message}")
  end
  kind = info.unwrap!.kind
  if bad_name and (kind == "directory" or kind_of(name) != "")
    return problem(found, path, "the file name is not valid UTF-8")
  elsif kind == "directory" and project and name == DEPS_FOLDER
    return found
  elsif kind == "directory"
    return walk(path, found)
  elsif kind_of(name) == ""
    return found
  elsif kind == "link"
    return follow(path, found)
  end
  return Found(problems: found.problems, files: found.files.push(path))
end

# A link takes part when it names a file that exists and is not a folder.
def follow(path: String, found: Found) -> Found
  target = File.stat(path, IO_TIMEOUT)
  if target.ok? and target.unwrap!.kind != "directory"
    return Found(problems: found.problems, files: found.files.push(path))
  end
  return problem(found, path, "the symbolic link does not name a file")
end
