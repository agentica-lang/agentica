## The workspace of a project (docs/grammar/05b-modules.md): the root agentica.toml of a repository of packages has a
## `[workspace]` table, `repository = "https://host/owner/repo"` and `members = ["sqlite", "postgres"]` (the folders
## of the packages). A project that is the root or one of the members resolves a dependency on a member of its own
## repository (the same `git`, and a `subdir` that is a member) to the folder of the member instead of the cache, so a
## change there is seen at once. Every other project, and every package of deps/ or of the cache, has no workspace: the
## table is read only here, for the project of a build, and a package that has one is not asked about it.

import Paths from "../modules/import_path"
import Workspace from "../modules/workspace"
import GitSource from "git_source"
import Toml from "std/toml"
import Reader from "toml_read"

MANIFEST_FILE = "agentica.toml"
# The folder `agentica install` writes the packages to. A project inside it is a package, never in a workspace.
DEPS_FOLDER = "deps"
TABLE_KEYS = ["repository", "members"]

## The workspace of a project. root is the folder of the manifest that has the table ("" when the project is in none),
## repository its URL as written and folders the members as written, each a subdir of the repository.
export struct Members
  root: String
  repository: String
  folders: List[String]
end

## The workspace of a project that is in none.
export def none() -> Members
  return Members(root: "", repository: "", folders: [])
end

## Finds the workspace of the project whose manifest is in `project_dir` (a canonical path): the nearest manifest going
## up, from that folder, that has a `[workspace]` table, provided the project is that folder or a member of it. It
## stops at the first such manifest and at a project that is inside a deps/ folder. A manifest above the project that
## cannot be read or parsed is not looked at further (it is not the manifest of the project, and a build of the project
## does not depend on it); the table of the one found is checked, and a bad one is PKG-MANIFEST-INVALID.
export def find(workspace: Workspace.Workspace, project_dir: String) -> Result[Members]
  here = project_dir
  while here != ""
    parent = Paths.directory_of(here)
    if Paths.last_part(parent) == DEPS_FOLDER
      return ok(none())
    end
    file = Paths.join(here, MANIFEST_FILE)
    if workspace.file_exists.call(file)
      tables = try declared(workspace, file)
      if tables.size > 0
        return belongs(workspace, here, file, tables[0], project_dir)
      end
    end
    if parent == here
      return ok(none())
    end
    here = parent
  end
  return ok(none())
end

## Whether a dependency source names a member of this workspace: its repository is the workspace's, and its subdir is a
## member.
export def member?(members: Members, source: GitSource.Source) -> Bool
  if members.root == "" or source.subdir == ""
    return false
  end
  if GitSource.identity(source.git) != GitSource.identity(members.repository)
    return false
  end
  return members.folders.any? do |folder| folder == source.subdir end
end

## The folder of the member that a source names (`member?` is true for it).
export def folder_of(members: Members, source: GitSource.Source) -> String
  return Paths.join(members.root, source.subdir)
end

# The `workspace` table of the manifest at file, as its entries: a list of one table, or of none when the file has no
# such table. A file that cannot be read or parsed has none here: the project's own manifest was read before and
# reports its own failure.
def declared(workspace: Workspace.Workspace, file: String) -> Result[List[Map[String, Toml.Value]]]
  reading = Reader.Reading(file: file, code: "PKG-MANIFEST-INVALID")
  text = Reader.read_text(workspace, reading)
  if !text.ok?
    return ok([])
  end
  root = Reader.parse(reading, text.unwrap!)
  if !root.ok? or !root.unwrap!.has_key?("workspace")
    return ok([])
  end
  table = try Reader.table(reading, root.unwrap!["workspace"], "workspace")
  return ok([table])
end

# The checked table of the manifest at root_dir, and the answer for the project: the workspace when the project is the
# root or a member, else none.
def belongs(
  workspace: Workspace.Workspace,
  root_dir: String,
  file: String,
  table: Map[String, Toml.Value],
  project_dir: String,
) -> Result[Members]
  reading = Reader.Reading(file: file, code: "PKG-MANIFEST-INVALID")
  try Reader.known_keys(reading, table, TABLE_KEYS, "workspace")
  repository = try repository_of(reading, table)
  folders = try folders_of(workspace, reading, table, root_dir)
  members = Members(root: root_dir, repository: repository, folders: folders)
  if root_dir == project_dir
    return ok(members)
  end
  for folder in folders
    path = Paths.join(root_dir, folder)
    if path == project_dir or workspace.real_path.call(path).unwrap_or(path) == project_dir
      return ok(members)
    end
  end
  return ok(none())
end

def repository_of(reading: Reader.Reading, table: Map[String, Toml.Value]) -> Result[String]
  path = Reader.child("workspace", "repository")
  if !table.has_key?("repository")
    return error(Reader.fail_help(reading, path, "missing key", "repository = \"https://host/owner/repo\""))
  end
  repository = try Reader.text(reading, table["repository"], path)
  problem = GitSource.git_problem(repository)
  if problem != ""
    return error(Reader.fail_help(reading, path, "not a git URL", problem))
  end
  return ok(repository)
end

# The members: subdirs of the repository (the same rules as `subdir`), each once, each a folder with its own manifest.
def folders_of(
  workspace: Workspace.Workspace,
  reading: Reader.Reading,
  table: Map[String, Toml.Value],
  root_dir: String,
) -> Result[List[String]]
  path = Reader.child("workspace", "members")
  if !table.has_key?("members")
    return error(Reader.fail_help(reading, path, "missing key", "members = [\"sqlite\", \"postgres\"]"))
  end
  items = try Reader.array(reading, table["members"], path)
  if items.size == 0
    return error(Reader.fail_help(reading, path, "a workspace has members", "list the folders of its packages"))
  end
  folders: List[String] = []
  for index in 0...items.size
    here = Reader.item(path, index)
    folder = try Reader.text(reading, items[index], here)
    problem = GitSource.subdir_problem(folder)
    if problem != ""
      return error(Reader.fail_help(reading, here, "not a member folder", problem))
    end
    if folders.any? do |seen| seen == folder end
      return error(Reader.fail(reading, here, "member listed twice"))
    end
    manifest = Paths.join(Paths.join(root_dir, folder), MANIFEST_FILE)
    if !workspace.file_exists.call(manifest)
      help = "write #{folder}/#{MANIFEST_FILE}"
      return error(Reader.fail_help(reading, here, "a member has an agentica.toml", help))
    end
    folders = folders.push(folder)
  end
  return ok(folders)
end
