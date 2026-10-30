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
export def empty() -> Members
  return Members(root: "", repository: "", folders: [])
end

## Finds the workspace of the project whose manifest is in `project_dir` (a canonical path): the nearest manifest going
## up, from that folder, that has a `[workspace]` table, provided the project is that folder or one of its listed
## members. A project whose folder is directly inside a folder named `deps` is a package and has none. A manifest above
## that cannot be read or parsed is passed over. The table is checked in full only when the project is in the
## workspace: a project below a broken table that does not list it builds as if the table were not there, unless the
## project folder is the root itself, which reports the table. A bad table is PKG-MANIFEST-INVALID.
export def find(workspace: Workspace.Workspace, project_dir: String) -> Result[Members]
  if Paths.last_part(Paths.directory_of(project_dir)) == DEPS_FOLDER
    return ok(empty())
  end

  here = project_dir
  while here != ""
    file = Paths.join(here, MANIFEST_FILE)
    if workspace.file_exists.call(file)
      tables = declared(workspace, file)
      if tables.size > 0
        return belongs(workspace, here, file, tables[0], project_dir)
      end
    end

    parent = Paths.directory_of(here)
    if parent == here
      return ok(empty())
    end

    here = parent
  end

  return ok(empty())
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

# The value of the `workspace` key of the manifest at file, as a list of one value, or of none when the file has no
# such key. A file that cannot be read or parsed has none here: the project's own manifest was read before and reports
# its own failure.
def declared(workspace: Workspace.Workspace, file: String) -> List[Toml.Value]
  reading = Reader.Reading(file: file, code: "PKG-MANIFEST-INVALID")
  text = Reader.read_text(workspace, reading)
  if !text.ok?
    return []
  end

  root = Reader.parse(reading, text.unwrap!)
  if !root.ok? or !root.unwrap!.has_key?("workspace")
    return []
  end

  return [root.unwrap!["workspace"]]
end

# The answer for the project when the manifest at root_dir has the `workspace` value: the workspace when the project is
# the root or is listed in its members (and the table is good), else none. Whether the project is listed is read from
# the raw value, so a table that is broken elsewhere is not looked at for a project that is not in it.
def belongs(
  workspace: Workspace.Workspace,
  root_dir: String,
  file: String,
  value: Toml.Value,
  project_dir: String,
) -> Result[Members]
  if root_dir != project_dir and !listed?(value, relative_to(root_dir, project_dir))
    return ok(empty())
  end

  reading = Reader.Reading(file: file, code: "PKG-MANIFEST-INVALID")
  table = try Reader.table(reading, value, "workspace")
  try Reader.known_keys(reading, table, TABLE_KEYS, "workspace")
  repository = try repository_of(reading, table)
  folders = try folders_of(workspace, reading, table, root_dir)
  return ok(Members(root: root_dir, repository: repository, folders: folders))
end

# The path of dir below root_dir, written with "/": "" when dir is not below it.
def relative_to(root_dir: String, dir: String) -> String
  prefix = root_dir
  if !prefix.ends_with?("/")
    prefix = "#{prefix}/"
  end

  if !dir.starts_with?(prefix)
    return ""
  end

  return dir.slice(prefix.length, dir.length - prefix.length)
end

# Whether the raw `workspace` value lists the folder `relative` among its members: false for anything that is not a
# table with a `members` array.
def listed?(value: Toml.Value, relative: String) -> Bool
  if relative == ""
    return false
  end

  case value
    Toml.Value.Table(entries) ->
      if !entries.has_key?("members")
        return false
      end

      case entries["members"]
        Toml.Value.Array(items) -> return items.any? do |item| names?(item, relative) end
        _ -> return false
      end

    _ -> return false
  end
end

def names?(item: Toml.Value, relative: String) -> Bool
  case item
    Toml.Value.Str(content) -> return content == relative
    _ -> return false
  end
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
