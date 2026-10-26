## The files a `symbol` query starts from (docs/future/39-semantic-cli.md, 39.4): the `PATH...` of the command line,
## each a file or a folder. A folder means every `*.agc` file under it, recursively, without hidden folders,
## `agc_libs/` folders and the `deps/` of a project (a folder beside an `agentica.toml`: the installed packages, not
## the project's own modules; name `deps/NAME` as a path to read one), in bytewise order of the path; a link is never
## followed, so a file reached twice is not read twice. `.agc` and `agc_libs` are compared without regard to case, as
## the package hash does (package_hash.agc). The arguments keep their order, and a file named twice (by another
## spelling too) comes once. The folders are read through the Workspace of the settings, so the query stays in the pure
## core.

import Problems from "../diagnostics/problem"
import Paths from "../modules/import_path"
import Workspace from "../modules/workspace"
import PackageHash from "../packages/package_hash"
import QueryOptions from "query_options"

# The folder a query reads when the command line names none.
DEFAULT_PATH = "."

# The manifest of a project, and the folder beside it that holds its installed packages.
MANIFEST_FILE = "agentica.toml"
DEPS_FOLDER = "deps"

## One file a query links: the path as it was typed or listed (a diagnostic names it so), and the canonical path that
## keys its module, so one file has one root whatever its spelling.
export struct Root
  typed: String
  key: String
end

## The files of the arguments, or why they do not name any.
export enum Expanded
  Files(List[Root])
  Refused(Problems.Problem)
end

# The files one argument names, or why it names none.
enum Listed
  Files(List[String])
  Refused(Problems.Problem)
end

## The roots of `paths` (the folder `.` when there are none), in order and without repeats. `buffer` is the FILE of
## `--stdin` ("" without it): the buffer is a root of its own, and the first one, since it is the file being edited. A
## path that is neither a file nor a folder, a folder that cannot be listed and a folder with no `*.agc` file are
## QUERY-USAGE, with `usage` as the help.
export def expand(
  workspace: Workspace.Workspace,
  paths: List[String],
  buffer: String,
  usage: String,
) -> Expanded
  asked = paths
  if asked.size == 0
    asked = [DEFAULT_PATH]
  end

  roots: List[Root] = []
  if buffer != ""
    roots = [root_of(workspace, buffer)]
  end

  return with_paths(workspace, roots, asked, usage)
end

## The roots of the position form of `refs`: `file`, the file of the position, first, then the files of `paths`, which
## may be none (the folder `.` is not a default here: the file alone is linked).
export def expand_from(workspace: Workspace.Workspace, file: String, paths: List[String], usage: String) -> Expanded
  return with_paths(workspace, [root_of(workspace, file)], paths, usage)
end

# `roots` and then the files of `asked`, in order and without repeats.
def with_paths(workspace: Workspace.Workspace, roots: List[Root], asked: List[String], usage: String) -> Expanded
  found = roots
  for path in asked
    case files_of(workspace, trimmed(path), usage)
      Listed.Refused(problem) -> return Expanded.Refused(problem)
      Listed.Files(typed) ->
        for file in typed
          found = with_root(found, root_of(workspace, file))
        end
    end
  end

  return Expanded.Files(found)
end

def files_of(workspace: Workspace.Workspace, path: String, usage: String) -> Listed
  if workspace.directory_exists.call(path)
    found = walk(workspace, path)
    if !found.ok?
      return Listed.Refused(QueryOptions.refusal("cannot read the folder #{found.message}", usage))
    elsif found.unwrap!.size == 0
      return Listed.Refused(QueryOptions.refusal("no .agc file under #{path}", usage))
    end

    return Listed.Files(found.unwrap!.sort)
  elsif workspace.file_exists.call(path)
    return Listed.Files([path])
  end

  return Listed.Refused(QueryOptions.refusal("cannot read #{path}", usage))
end

# Every `*.agc` file under `folder`, listed folder by folder with a worklist. The error is the folder that cannot be
# listed.
def walk(workspace: Workspace.Workspace, folder: String) -> Result[List[String]]
  files: List[String] = []
  pending = [folder]
  at = 0
  while at < pending.size
    here = pending[at]
    at += 1
    listed = workspace.list_folder.call(here)
    if !listed.ok?
      return error(here)
    end

    project = listed.unwrap!.any? do |entry| entry.name == MANIFEST_FILE end
    for entry in listed.unwrap!
      path = child(here, entry.name)
      case entry.kind
        Workspace.EntryKind.File ->
          if PackageHash.source_file?(entry.name)
            files = files.push(path)
          end

        Workspace.EntryKind.Directory ->
          # The package hash decides what a build loads, in any case of the names; `top` is true at every depth, so
          # a nested agc_libs/ is left out too, as the query always did.
          if !PackageHash.skipped_folder?(entry.name, true) and !(project and entry.name == DEPS_FOLDER)
            pending = pending.push(path)
          end

        Workspace.EntryKind.Link -> files = files
        Workspace.EntryKind.Other -> files = files
      end
    end
  end

  return ok(files)
end

# The path of `name` in `folder`; the working folder adds no "./" to what it holds.
def child(folder: String, name: String) -> String
  if folder == DEFAULT_PATH
    return name
  end

  return Paths.join(folder, name)
end

# A path without the separators that end it, which the Workspace does not take (the root folder keeps its one).
def trimmed(path: String) -> String
  kept = path
  while kept.length > 1 and kept.ends_with?("/")
    kept = kept.slice(0, kept.length - 1)
  end

  return kept
end

# A file that the disk (or the buffer) cannot resolve keeps its typed path as its key.
def root_of(workspace: Workspace.Workspace, typed: String) -> Root
  return Root(typed: typed, key: workspace.real_path.call(typed).unwrap_or(typed))
end

def with_root(roots: List[Root], root: Root) -> List[Root]
  if roots.any? do |known: Root| known.key == root.key end
    return roots
  end

  return roots.push(root)
end
