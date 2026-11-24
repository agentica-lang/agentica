## Fills the package cache from the lock (docs/grammar/05b-modules.md). One locked package goes into the folder of
## its commit: a depth-1 fetch of the tag (or of the commit) into a bare repository made for the purpose, with no hooks
## and no working tree, so nothing of the package runs. The files of the commit are read from its tree with `git
## ls-tree` and `git cat-file`, so `.gitattributes` does not change the bytes; only the `.agc` files and the manifest
## are copied (package_tree.agc), and the hash of what was copied must be the hash of the lock. A package that is a
## folder of the repository (`subdir`) is fetched the same way, but only the files of that folder are read and kept, in
## a cache folder of its own (package_cache.agc). The files are built in a folder of the cache root and renamed into
## place in one step, so the cache never holds half a package. A folder that is already in place is hashed, never
## overwritten. A failure is a packed failure that names the lock and the key of the entry (link_failure.agc,
## fail_key).
## `fill` fetches what the lock names; `fill_group` does it for several packages of one repository, pin and commit with
## one fetch. `resolve` (for `add` and `update`) fetches a pin that has no commit or hash yet,
## learns both from what it fetched, and puts the files in the cache by the same steps.

import Diag from "../diagnostics/diagnostic"
import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import Workspace from "../modules/workspace"
import GitSource from "../packages/git_source"
import Lock from "../packages/lock"
import Members from "../packages/members"
import PackageCache from "../packages/package_cache"
import PackageHash from "../packages/package_hash"
import Tree from "../packages/package_tree"
import Reader from "../packages/toml_read"
import VersionRequirement from "../packages/version_requirement"
import GitProcess from "git_process"
import Toml from "std/toml"

## What filling one package did: the files were fetched, or the folder was already there with the locked hash.
enum Filled
  Fetched
  Present
end

## Where the package is in the lock: the file and the path of its `[[package]]` table, such as `package[2]`.
struct Place
  file: String
  entry: String
end

## A package of the lock to put in the cache: the entry of the lock it is in, and the locked package.
struct Entry
  place: Place
  locked: Lock.Locked
end

## One thing that a manifest asks of the tag of a package: a `version` requirement (`text`), or a `tag` pin that
## reads as a version (an exact one), the package whose manifest asked (`by`, "" for the project's) and that
## manifest (`file`).
struct Ask
  text: String
  tag: String
  by: String
  file: String
end

## The folder of the package cache, or the failure for `file` (the lock, whose entries are about to be filled) when the
## environment leaves no place for it.
def cache_root(env: Env.Env, file: String) -> Result[String]
  cache = PackageCache.root(env)
  if cache == ""
    message = "there is no package cache folder: HOME is not set"
    return error(Failure.fail_file(file, "PKG-FETCH", message, Failure.hint("set HOME or XDG_CACHE_HOME")))
  end

  ok(cache)
end

## Like `cache_root`, for the packages of a lock: a lock of workspace members and paths alone fetches nothing and
## needs no cache, so it gives "" for it and fails only when a package has to be fetched.
def cache_for(env: Env.Env, file: String, packages: List[Lock.Locked]) -> Result[String]
  return ok("") if packages.all? do |locked| Lock.in_place?(locked) end

  cache_root(env, file)
end

## Puts the files of the locked package into the cache under `cache` (a folder; PackageCache.root).
def fill(workspace: Workspace.Workspace, cache: String, place: Place, locked: Lock.Locked) -> Result[Filled]
  filled = try fill_group(workspace, cache, [Entry(place: place, locked: locked)])
  ok(filled[0])
end

## Puts the files of locked packages into the cache with one fetch: the packages are folders of one repository (or the
## repository itself) at one pin and commit, so one temporary repository serves all of them, and git runs once for the
## group whatever its size. The answers are in the order of `entries`, which are not empty. A package that is in the
## cache with the locked hash is not fetched, and when every one is, git does not run. A failure of the fetch names the
## first entry that needed it.
def fill_group(workspace: Workspace.Workspace, cache: String, entries: List[Entry]) -> Result[List[Filled]]
  absent: List[Entry] = []
  for entry in entries
    target = PackageCache.folder(cache, entry.locked.source, entry.locked.commit)
    seen = try inspect(workspace, entry.place, target, entry.locked)
    case seen
      Seen.Matches -> next
      Seen.Absent -> absent = absent.push(entry)
    end
  end

  fetched: Map[String, Filled] = {}
  if absent.size > 0
    fetched = try fetch_all(workspace, cache, absent)
  end

  ok(entries.map do |entry: Entry| fetched.get(entry.locked.name).unwrap_or(Filled.Present) end)
end

## Fetches the pin of a package that is not locked yet, for `add` and `update`: the lock entry it gives has the commit
## that the pin points to and the hash of the files, and the files are in the cache as `fill` would put them. A tag may
## point anywhere now (that is what `update` is for); a `ref` must be the whole commit, since git cannot fetch an
## abbreviation. `place` names the dependency in the manifest that asks for it.
def resolve(
  workspace: Workspace.Workspace,
  cache: String,
  place: Place,
  name: String,
  source: GitSource.Source,
) -> Result[Lock.Locked]
  if source.ref != "" and source.ref.length != 40 and source.ref.length != 64
    message = "git fetches a commit by its whole id, and #{source.ref} is only a part of it"
    return error(fail(place, "PKG-FETCH", "ref", message, "write the 40 (or 64) digits of the commit"))
  end

  # A ref is the commit already; a tag's commit is learnt from the fetch.
  pin = Lock.Locked(
    name: name,
    source: source,
    commit: source.ref,
    hash: "",
    member: false,
    override: false,
    repository: "",
  )

  made = make_temp(cache)
  if !made.ok?
    return error(fail(place, "PKG-FETCH", "", "cannot make a folder in the package cache #{cache}", made.message))
  end

  temp = made.unwrap!
  scratch = Scratch(temp: temp, repo: Paths.join(temp, "repo.git"), files: Paths.join(temp, "files"))
  resolved = resolve_into(workspace, cache, place, scratch, pin)
  # As in fetch: a temporary folder that cannot be removed does not change the answer.
  remove_temp(temp)
  resolved
end

## Fetches the pin of a workspace dependency, for `add` and `update`: with one fetch it reads the `[workspace]` table
## of the root `agentica.toml` at the commit and puts every member in the cache as `resolve` would put a package that
## is a folder of the repository. It gives the entry of the workspace (`name`, the commit, the `repository` of the
## table and no hash) followed by one entry for each member, named `name/folder` and pinned as the workspace is. A
## repository with no `[workspace]` table, a table that its rules refuse and a member without a manifest are PKG-FETCH
## at `workspace` of the dependency that `place` names, as is a root manifest that cannot be read.
def resolve_workspace(
  workspace: Workspace.Workspace,
  cache: String,
  place: Place,
  name: String,
  source: GitSource.Source,
) -> Result[List[Lock.Locked]]
  if source.ref != "" and source.ref.length != 40 and source.ref.length != 64
    message = "git fetches a commit by its whole id, and #{source.ref} is only a part of it"
    return error(fail(place, "PKG-FETCH", "ref", message, "write the 40 (or 64) digits of the commit"))
  end

  pin = Lock.Locked(
    name: name,
    source: source,
    commit: source.ref,
    hash: "",
    member: false,
    override: false,
    repository: "",
  )

  made = make_temp(cache)
  if !made.ok?
    return error(fail(place, "PKG-FETCH", "", "cannot make a folder in the package cache #{cache}", made.message))
  end

  temp = made.unwrap!
  scratch = Scratch(temp: temp, repo: Paths.join(temp, "repo.git"), files: Paths.join(temp, "files"))
  resolved = workspace_into(workspace, cache, place, scratch, pin)
  remove_temp(temp)
  resolved
end

## The folder of the repository that `add` takes for a tag `NAME-X.Y.Z` with no `--subdir` (`package` is NAME): NAME
## when the tagged commit has the file NAME/agentica.toml and its root has no agentica.toml whose `name` is NAME, else
## "" (the repository itself). The tag is fetched as `resolve` fetches it, and `git ls-tree -l` of the commit lists
## only the two manifests; the root one is read with `git cat-file` (manifest_blobs). `place` names the dependency.
def tag_subdir(
  workspace: Workspace.Workspace,
  cache: String,
  place: Place,
  source: GitSource.Source,
  package: String,
) -> Result[String]
  made = make_temp(cache)
  if !made.ok?
    return error(fail(place, "PKG-FETCH", "", "cannot make a folder in the package cache #{cache}", made.message))
  end

  temp = made.unwrap!
  scratch = Scratch(temp: temp, repo: Paths.join(temp, "repo.git"), files: Paths.join(temp, "files"))
  pin = Lock.Locked(
    name: package,
    source: source,
    commit: "",
    hash: "",
    member: false,
    override: false,
    repository: "",
  )

  found = subdir_in(place, scratch, pin, package)
  remove_temp(temp)
  found
end

## What a dependency asks of the tag, or none when it asks nothing that other asks can meet: a `version`, or a `tag`
## that is a version of the repository or folder (`X.Y.Z`, `vX.Y.Z`, or `NAME-X.Y.Z` with a subdir).
def ask_for(source: GitSource.Source, by: String, file: String) -> Optional[Ask]
  return some(Ask(text: source.version, tag: "", by: by, file: file)) if source.version != ""

  prefix = VersionRequirement.tag_prefix(source.subdir)
  return none if source.tag == "" or !VersionRequirement.tag_version(source.tag, prefix).some?

  some(Ask(text: "", tag: source.tag, by: by, file: file))
end

## Whether the tag meets every ask: it is a version of the repository or folder, equal to each pinned tag and
## satisfying each requirement.
def fits?(subdir: String, tag: String, asks: List[Ask]) -> Bool
  prefix = VersionRequirement.tag_prefix(subdir)
  return false if !VersionRequirement.tag_version(tag, prefix).some?

  asks.all? do |ask: Ask| meets?(ask, tag, prefix) end
end

## The names of the tags of a repository, from `git ls-remote --tags --refs` (the only place that lists tags, so
## install and the build stay offline). A name that is not UTF-8 comes scrubbed, so it reads as no version. A git that
## fails is PKG-FETCH at `place`.
def list_tags(cache: String, place: Place, git_url: String) -> Result[List[String]]
  made = make_temp(cache)
  if !made.ok?
    return error(fail(place, "PKG-FETCH", "", "cannot make a folder in the package cache #{cache}", made.message))
  end

  temp = made.unwrap!
  scratch = Scratch(temp: temp, repo: Paths.join(temp, "repo.git"), files: Paths.join(temp, "files"))
  listed = git(place, scratch, ["ls-remote", "--tags", "--refs", "--", git_url])
  remove_temp(temp)
  listing = try listed
  ok(tag_names(listing.scrub))
end

## The tag that a `version` dependency takes now, for `add` and `update`: the highest of `tags` (`list_tags`) that
## meets every ask for the package, the requirements of the whole tree and the tags it pins (`asks`, which hold the
## one of `source`). It gives the source with that `tag` besides its `version`. A repository with no such tag is
## PKG-VERSION-UNSATISFIED at `version` of the dependency that `place` names, with who asked for what in the message
## and the newest tags that read as a version in the help.
def choose_tag(
  place: Place,
  name: String,
  source: GitSource.Source,
  asks: List[Ask],
  tags: List[String],
) -> Result[GitSource.Source]
  requirements: List[VersionRequirement.Requirement] = []
  pins: List[String] = []
  for ask in asks
    if ask.tag != ""
      pins = pins.push(ask.tag)
      next
    end

    requirement = VersionRequirement.parse(ask.text)
    if !requirement.ok?
      return error(fail(place, "PKG-MANIFEST-INVALID", "version", "not a version requirement", requirement.message))
    end

    requirements = requirements.push(requirement.unwrap!)
  end

  prefix = VersionRequirement.tag_prefix(source.subdir)
  candidates = tags
  if pins.size > 0
    candidates = tags.select do |tag: String| pins.all? do |pin: String| pin == tag end end
  end

  chosen = VersionRequirement.highest(requirements, candidates, prefix)
  return ok(source.with(tag: chosen.unwrap!)) if chosen.some?

  seen = VersionRequirement.newest(tags, prefix, SEEN_TAGS)
  help = "the repository has no tag that reads as a version (#{tag_shape(prefix)})"
  if seen.size > 0
    help = "the newest tags are #{seen.join(", ")}"
  end

  error(unsatisfied(place, "version", name, source, asks, help))
end

## PKG-VERSION-UNSATISFIED at `key` of the dependency `place` names: no tag of the repository meets the asks, and the
## message says who asked for what.
def unsatisfied(
  place: Place,
  key: String,
  name: String,
  source: GitSource.Source,
  asks: List[Ask],
  help: String,
) -> String
  message = "no tag of #{source.git} satisfies the version #{source.version}"
  if asks.size > 1
    message = "no tag of #{source.git} meets what #{name} is asked for: #{who_asked(asks)}"
  end

  fail(place, "PKG-VERSION-UNSATISFIED", key, message, help)
end

## The names of the tags in the output of `git ls-remote --tags --refs`: a line is a commit, a tab, `refs/tags/NAME`. A
## name that is not UTF-8 comes scrubbed, so it reads as no version and the other tags still count.
def tag_names(listing: String) -> List[String]
  names: List[String] = []
  for line in listing.split("\n")
    columns = line.strip.split("\t")
    next if columns.size != 2 or !columns[1].start_with?(TAGS_PREFIX)

    names = names.push(columns[1].slice(TAGS_PREFIX.length, columns[1].length - TAGS_PREFIX.length))
  end

  names
end

def tag_shape(prefix: String) -> String
  return "X.Y.Z or vX.Y.Z" if prefix == ""

  "#{prefix}X.Y.Z"
end

## The failure for the key of an entry ("" for the entry as a whole). An empty help is no help.
def fail(place: Place, code: String, key: String, message: String, help: String) -> String
  path = Reader.child(place.entry, key)
  if key == ""
    path = place.entry
  end

  return Failure.fail_key(place.file, path, code, message, Diag.Help.NoHelp) if help == ""

  Failure.fail_key(place.file, path, code, message, Failure.hint(help))
end

private

# The deadline of one file-system call, in milliseconds.
FS_TIMEOUT_MS = 60_000
TEMP_TRIES = 5
# Where the fetched pin lands in the temporary repository. It is not under refs/tags/, so the name cannot clash with a
# tag of the repository.
PINNED = "refs/fetched/pin"
# The tags that a failure of a requirement lists, and the start of the name of a tag in `git ls-remote`.
SEEN_TAGS = 5
TAGS_PREFIX = "refs/tags/"
# The number of characters of git's error text that goes in the help.
HELP_LIMIT = 600
MANIFEST = "agentica.toml"
FILE_MODES = Set.new(["100644", "100755"])
NUL = String.from_code(0)

# The temporary folder of one fetch: the bare repository, and the files that are copied out of it. git runs in `temp`.
struct Scratch
  temp: String
  repo: String
  files: String
end

# What a folder of the cache holds under the commit: nothing, or the locked files.
enum Seen
  Absent
  Matches
end

# Looks at the folder of the commit, if there is one: the locked files (nothing to do) or others (an error).
def inspect(workspace: Workspace.Workspace, place: Place, target: String, locked: Lock.Locked) -> Result[Seen]
  return ok(Seen.Absent) if !workspace.directory_exists.call(target) and !workspace.file_exists.call(target)

  real = workspace.real_path.call(target)
  return error(fail(place, "PKG-FETCH", "", "cannot read #{target}", real.message)) if !real.ok?

  case PackageHash.hash_folder(workspace, real.unwrap!)
    PackageHash.Hashed.Hash(found) ->
      return ok(Seen.Matches) if found == locked.hash

      message = "the files of #{locked.name} in the cache are not the ones the lock names"
      error(fail(place, "PKG-HASH-MISMATCH", "hash", message, "remove #{target} and run install again"))
    PackageHash.Hashed.Link(path) ->
      error(fail(place, "PKG-SYMLINK", "", "#{locked.name} has a symbolic link named #{path}", ""))
    PackageHash.Hashed.Unreadable(message) -> error(fail(place, "PKG-FETCH", "", "cannot read #{target}", message))
  end
end

# Fetches the pin once into a temporary folder of the cache root, which is removed whatever happens, and puts the
# files of each entry (one folder of the repository, or all of it) into the cache folder of its commit. The entries are
# not empty and share one repository, pin and commit. The answers are by lock name.
def fetch_all(workspace: Workspace.Workspace, cache: String, entries: List[Entry]) -> Result[Map[String, Filled]]
  made = make_temp(cache)
  if !made.ok?
    return error(
      fail(entries[0].place, "PKG-FETCH", "", "cannot make a folder in the package cache #{cache}", made.message),
    )
  end

  temp = made.unwrap!
  filled = fetch_into(workspace, cache, temp, entries)
  # A folder that cannot be removed stays hidden in the cache root, and the result of the install stands: the failure
  # to clean up is not worth failing a fetch that worked (or hiding the error of one that did not).
  remove_temp(temp)
  filled
end

# git writes its objects read-only and Path.remove refuses a read-only entry on Windows, so `attrib` clears the
# attribute of the whole tree first. A failure of either step leaves the folder, as before. attrib runs in the working
# folder, not in `temp`: a running child holds its folder open on Windows, and then Path.remove could not remove it.
def remove_temp(temp: String) -> Void
  if System.os() == "windows"
    pattern = Paths.join(temp, "*").replace("/", "\\")
    spawned = Process.spawn_captured("attrib", ["-R", "/S", "/D", pattern], Process.Options(timeout_ms: FS_TIMEOUT_MS))
    if spawned.ok?
      child = spawned.unwrap!
      _ = Process.wait(child, FS_TIMEOUT_MS)
      Process.close(child)
    end
  end

  _ = Path.remove(temp, FS_TIMEOUT_MS)
end

# A new folder that only this process uses: mkdir_private fails when the name exists, so two installs never share one.
# It is hidden and directly under the root, where no host folder starts with a dot (GitSource.git_problem).
def make_temp(cache: String) -> Result[String]
  try Dir.mkdir(cache, FS_TIMEOUT_MS)
  failure = "no free name"
  for _ in 0...TEMP_TRIES
    name = Paths.join(cache, ".tmp-#{System.pid()}-#{Random.int(0, 999_999_999)}")
    made = Dir.mkdir_private(name, FS_TIMEOUT_MS)
    return ok(name) if made.ok?

    failure = made.message
  end

  error(failure)
end

def fetch_into(
  workspace: Workspace.Workspace,
  cache: String,
  temp: String,
  entries: List[Entry],
) -> Result[Map[String, Filled]]
  first = entries[0]
  scratch = Scratch(temp: temp, repo: Paths.join(temp, "repo.git"), files: Paths.join(temp, "files"))
  try init_repository(first.place, scratch, first.locked)
  try fetch_pin(first.place, scratch, first.locked)
  try check_commit(first.place, scratch, first.locked)
  done: Map[String, Filled] = {}
  for index in 0...entries.size
    entry = entries[index]
    here = scratch.with(files: Paths.join(temp, "files-#{index}"))
    try copy_tree(entry.place, here, entry.locked.commit, entry.locked.source.subdir)
    try check_hash(workspace, entry.place, here.files, entry.locked)
    target = PackageCache.folder(cache, entry.locked.source, entry.locked.commit)
    done = done.put(entry.locked.name, try move_into_place(workspace, entry.place, here.files, target, entry.locked))
  end

  ok(done)
end

# The files of the commit that the hash covers (and the manifest) go to scratch.files. For a package that is a folder
# of the repository the listing is the tree `<commit>:<subdir>`, so its paths are relative to the folder and nothing
# outside it is listed, read or written.
def copy_tree(place: Place, scratch: Scratch, commit: String, subdir: String) -> Result[Void]
  tree = commit
  if subdir != ""
    tree = "#{commit}:#{subdir}"
    try check_subdir(place, scratch, tree)
  end

  listing = try git_text(place, scratch, inside(scratch, ["ls-tree", "-r", "-z", "-l", tree]))
  case Tree.plan(listing)
    Tree.Plan.Refused(fault) -> error(fail(place, fault.code, fault.key, fault.message, fault.help))
    Tree.Plan.Files(blobs) -> copy_blobs(place, scratch, blobs)
  end
end

# The subdir must be a folder of the commit. Only this question is answered at the subdir key: the commit was fetched
# and peeled already, so a path that git cannot find, or that is a file, a link or a submodule (git cannot read the
# commit it names), is the entry's fault, while a later failure of git (ls-tree, a damaged repository) is git's.
def check_subdir(place: Place, scratch: Scratch, tree: String) -> Result[Void]
  kind = try git_at(place, scratch, "subdir", inside(scratch, ["cat-file", "-t", tree]))
  if String.from_bytes(kind).unwrap_or("").strip != "tree"
    return error(fail(place, "PKG-FETCH", "subdir", "#{tree} is not a folder", ""))
  end

  ok()
end

def resolve_into(
  workspace: Workspace.Workspace,
  cache: String,
  place: Place,
  scratch: Scratch,
  pin: Lock.Locked,
) -> Result[Lock.Locked]
  try init_repository(place, scratch, pin)
  try fetch_pin(place, scratch, pin)
  commit = try peel(place, scratch)
  if pin.source.ref != "" and commit != pin.source.ref
    return error(fail(place, "PKG-FETCH", "ref", "git fetched #{commit}, not #{pin.source.ref}", ""))
  end

  try copy_tree(place, scratch, commit, pin.source.subdir)
  hash = try hash_of(workspace, place, pin, scratch.files)
  locked = Lock.Locked(
    name: pin.name,
    source: pin.source,
    commit: commit,
    hash: hash,
    member: false,
    override: false,
    repository: "",
  )

  target = PackageCache.folder(cache, locked.source, commit)
  try move_into_place(workspace, place, scratch.files, target, locked)
  ok(locked)
end

def workspace_into(
  workspace: Workspace.Workspace,
  cache: String,
  place: Place,
  scratch: Scratch,
  pin: Lock.Locked,
) -> Result[List[Lock.Locked]]
  try init_repository(place, scratch, pin)
  try fetch_pin(place, scratch, pin)
  commit = try peel(place, scratch)
  if pin.source.ref != "" and commit != pin.source.ref
    return error(fail(place, "PKG-FETCH", "ref", "git fetched #{commit}, not #{pin.source.ref}", ""))
  end

  table = try workspace_table(place, scratch, commit)
  try members_apart(place, table.folders)
  try members_present(place, scratch, commit, table.folders)
  root = Lock.Locked(
    name: pin.name,
    source: pin.source,
    commit: commit,
    hash: "",
    member: false,
    override: false,
    repository: table.repository,
  )

  found = [root]
  for index in 0...table.folders.size
    folder = table.folders[index]
    source = pin.source.with(subdir: folder)

    member = Lock.Locked(
      name: "#{pin.name}/#{folder}",
      source: source,
      commit: commit,
      hash: "",
      member: false,
      override: false,
      repository: "",
    )

    here = scratch.with(files: Paths.join(scratch.temp, "files-#{index}"))
    try copy_tree(place, here, commit, folder)
    hash = try hash_of(workspace, place, member, here.files)
    stored = member.with(hash: hash)
    target = PackageCache.folder(cache, stored.source, commit)
    try move_into_place(workspace, place, here.files, target, stored)
    found = found.push(stored)
  end

  ok(found)
end

# The `[workspace]` table of the root agentica.toml of the commit: its repository and members. Anything that is not
# a good table is PKG-FETCH at `workspace` of the dependency: the repository is not a workspace.
def workspace_table(place: Place, scratch: Scratch, commit: String) -> Result[Members.Table]
  listing = try git_text(place, scratch, inside(scratch, ["ls-tree", "-z", "-l", commit, "--", MANIFEST]))
  blobs = manifest_blobs(listing)
  if !blobs.has_key?(MANIFEST)
    return error(fail(place, "PKG-FETCH", "workspace", "the repository has no #{MANIFEST} at its root", ""))
  end

  text = try git_text(place, scratch, inside(scratch, ["cat-file", "blob", blobs[MANIFEST]]))
  parsed = Toml.parse(text)
  if !parsed.ok?
    message = "the #{MANIFEST} of the repository is not TOML: #{parsed.message}"
    return error(fail(place, "PKG-FETCH", "workspace", message, ""))
  end

  case parsed.unwrap!
    Toml.Value.Table(entries) ->
      if !entries.has_key?("workspace")
        message = "the #{MANIFEST} of the repository has no [workspace] table"
        return error(
          fail(place, "PKG-FETCH", "workspace", message, "a workspace dependency names a repository of packages"),
        )
      end

      reading = Reader.Reading(file: MANIFEST, code: "PKG-FETCH")
      case Members.table_of(reading, entries["workspace"])
        ok(table) -> ok(table)
        error(packed) ->
          problem = Failure.unpack_failure(packed.message)
          message = (
            "the [workspace] table of the repository is not good: #{problem.key_path} #{problem.diagnostic.message}"
          )

          error(fail(place, "PKG-FETCH", "workspace", message, ""))
      end

    _ -> error(fail(place, "PKG-FETCH", "workspace", "the #{MANIFEST} of the repository is not a table", ""))
  end
end

# No member is inside another: deps/ keeps a member in a folder of its namespace, and the files of one member inside
# another would be hashed as the files of both.
def members_apart(place: Place, folders: List[String]) -> Result[Void]
  for folder in folders
    inner = folders.select do |other: String| folder.start_with?("#{other}/") end
    if inner.size > 0
      message = "the workspace member #{folder} is inside the member #{inner[0]}"
      return error(fail(place, "PKG-FETCH", "workspace", message, "a member is a folder of its own"))
    end
  end

  ok()
end

# Every member of the table is a folder of the commit with its own manifest, which one `ls-tree` of those paths shows.
def members_present(place: Place, scratch: Scratch, commit: String, folders: List[String]) -> Result[Void]
  paths = folders.map do |folder: String| "#{folder}/#{MANIFEST}" end
  listing = try git_text(place, scratch, inside(scratch, ["ls-tree", "-z", "-l", commit, "--"].concat(paths)))
  blobs = manifest_blobs(listing)
  for path in paths
    if !blobs.has_key?(path)
      message = "the workspace has a member whose #{path} is not a file of the commit"
      return error(fail(place, "PKG-FETCH", "workspace", message, "each member is a folder with an #{MANIFEST}"))
    end
  end

  ok()
end

def subdir_in(place: Place, scratch: Scratch, pin: Lock.Locked, package: String) -> Result[String]
  try init_repository(place, scratch, pin)
  try fetch_pin(place, scratch, pin)
  commit = try peel(place, scratch)
  folder_manifest = "#{package}/#{MANIFEST}"
  arguments = ["ls-tree", "-z", "-l", commit, "--", MANIFEST, folder_manifest]
  listing = try git_text(place, scratch, inside(scratch, arguments))
  blobs = manifest_blobs(listing)
  return ok("") if !blobs.has_key?(folder_manifest)
  return ok(package) if !blobs.has_key?(MANIFEST)

  root = try git(place, scratch, inside(scratch, ["cat-file", "blob", blobs[MANIFEST]]))
  return ok("") if root_name(String.from_bytes(root).unwrap_or("")) == package

  ok(package)
end

# The manifests of an `ls-tree -z -l` listing, path to blob id: regular files that a package may hold (at most
# PackageHash.MAX_FILE_BYTES). A link, a submodule or a larger file is no manifest of a package.
def manifest_blobs(listing: String) -> Map[String, String]
  blobs: Map[String, String] = {}
  for record in listing.split(NUL)
    tab = record.index_of("\t")
    next if tab.none?

    fields = record.slice(0, tab.unwrap!).split(" ").select do |field: String| field != "" end
    next if fields.size != 4 or !FILE_MODES.include?(fields[0])

    size = fields[3].to_i.unwrap_or(-1)
    if size >= 0 and size <= PackageHash.MAX_FILE_BYTES
      blobs = blobs.put(record.slice(tab.unwrap! + 1, record.length - tab.unwrap! - 1), fields[2])
    end
  end

  blobs
end

# The `name` of a manifest's text, "" when the text is not TOML or has no such string.
def root_name(text: String) -> String
  parsed = Toml.parse(text)
  return "" if !parsed.ok?

  case parsed.unwrap!
    Toml.Value.Table(entries) -> text_of(entries.get("name").unwrap_or(Toml.Value.Bool(false)))
    _ -> ""
  end
end

def text_of(value: Toml.Value) -> String
  case value
    Toml.Value.Str(text) -> text
    _ -> ""
  end
end

# An empty template, so a hook from the user's template folder cannot run.
def init_repository(place: Place, scratch: Scratch, locked: Lock.Locked) -> Result[Void]
  arguments = ["init", "--bare", "--quiet", "--template="]
  if locked.commit.length == 64
    arguments = arguments.push("--object-format=sha256")
  end

  try git(place, scratch, arguments.push(scratch.repo))
  ok()
end

# The url is passed as written: git's own url.<base>.insteadOf settings apply to it, and the lock keeps what the
# manifest says.
def fetch_pin(place: Place, scratch: Scratch, locked: Lock.Locked) -> Result[Void]
  wanted = "refs/tags/#{locked.source.tag}"
  if locked.source.tag == ""
    wanted = locked.commit
  end

  arguments = [
    "fetch",
    "--quiet",
    "--depth=1",
    "--no-tags",
    "--no-recurse-submodules",
    "--",
    locked.source.git,
    "+#{wanted}:#{PINNED}",
  ]

  try git(place, scratch, inside(scratch, arguments))
  ok()
end

# The fetched pin must be the locked commit; a tag that now points elsewhere is a moved tag, never a new lock.
def check_commit(place: Place, scratch: Scratch, locked: Lock.Locked) -> Result[Void]
  commit = try peel(place, scratch)
  return ok() if commit == locked.commit

  if locked.source.tag != ""
    message = "the tag #{locked.source.tag} of #{locked.name} is now #{commit}, and the lock has #{locked.commit}"
    return error(fail(place, "PKG-TAG-MOVED", "tag", message, "the lock is not changed; update it on purpose"))
  end

  error(fail(place, "PKG-FETCH", "commit", "git fetched #{commit}, not #{locked.commit}", ""))
end

# The commit that the fetched pin points to (a tag is peeled).
def peel(place: Place, scratch: Scratch) -> Result[String]
  arguments = ["rev-parse", "--verify", "--quiet", "#{PINNED}^{commit}"]
  peeled = try git_text(place, scratch, inside(scratch, arguments))
  ok(peeled.strip)
end

def copy_blobs(place: Place, scratch: Scratch, blobs: List[Tree.Blob]) -> Result[Void]
  made = Dir.mkdir(scratch.files, FS_TIMEOUT_MS)
  return error(fail(place, "PKG-FETCH", "", "cannot make #{scratch.files}", made.message)) if !made.ok?

  for blob in blobs
    data = try git(place, scratch, inside(scratch, ["cat-file", "blob", blob.oid]))
    try write_file(place, Paths.join(scratch.files, blob.path), data)
  end

  ok()
end

# A file is at most Tree.MAX_FILE_BYTES (1 MiB, the most File.write_bytes takes in one call), so it goes in one write.
def write_file(place: Place, path: String, data: Bytes) -> Result[Void]
  folder = Paths.directory_of(path)
  made = Dir.mkdir(folder, FS_TIMEOUT_MS)
  return error(fail(place, "PKG-FETCH", "", "cannot make #{folder}", made.message)) if !made.ok?

  opened = File.open(path, "write", FS_TIMEOUT_MS)
  return error(fail(place, "PKG-FETCH", "", "cannot write #{path}", opened.message)) if !opened.ok?

  handle = opened.unwrap!
  wrote = File.write_bytes(handle, data, FS_TIMEOUT_MS)
  if !wrote.ok?
    _ = File.close(handle, FS_TIMEOUT_MS)
    return error(fail(place, "PKG-FETCH", "", "cannot write #{path}", wrote.message))
  end

  closed = File.close(handle, FS_TIMEOUT_MS)
  return error(fail(place, "PKG-FETCH", "", "cannot write #{path}", closed.message)) if !closed.ok?

  ok()
end

def check_hash(workspace: Workspace.Workspace, place: Place, files: String, locked: Lock.Locked) -> Result[Void]
  found = try hash_of(workspace, place, locked, files)
  return ok() if found == locked.hash

  message = "the files fetched for #{locked.name} are not the ones the lock names (#{found})"
  error(fail(place, "PKG-HASH-MISMATCH", "hash", message, "the lock is not changed; update it on purpose"))
end

# The hash of the fetched files (the pin's, or the locked entry's, name is only for the messages).
def hash_of(workspace: Workspace.Workspace, place: Place, locked: Lock.Locked, files: String) -> Result[String]
  case PackageHash.hash_folder(workspace, files)
    PackageHash.Hashed.Hash(found) -> ok(found)
    PackageHash.Hashed.Link(path) ->
      error(fail(place, "PKG-SYMLINK", "", "#{locked.name} has a symbolic link named #{path}", ""))
    PackageHash.Hashed.Unreadable(message) ->
      error(fail(place, "PKG-FETCH", "", "cannot read the fetched files of #{locked.name}", message))
  end
end

# One rename, which never replaces: if another install put the package there first, its files are checked instead.
def move_into_place(
  workspace: Workspace.Workspace,
  place: Place,
  files: String,
  target: String,
  locked: Lock.Locked,
) -> Result[Filled]
  made = Dir.mkdir(Paths.directory_of(target), FS_TIMEOUT_MS)
  return error(fail(place, "PKG-FETCH", "", "cannot make the folder of #{target}", made.message)) if !made.ok?

  moved = Path.rename(files, target, FS_TIMEOUT_MS)
  return ok(Filled.Fetched) if moved.ok?

  seen = try inspect(workspace, place, target, locked)
  case seen
    Seen.Matches -> ok(Filled.Present)
    Seen.Absent -> error(fail(place, "PKG-FETCH", "", "cannot move the files to #{target}", moved.message))
  end
end

# The arguments of a git command that works on the temporary repository.
def inside(scratch: Scratch, arguments: List[String]) -> List[String] = ["--git-dir=#{scratch.repo}"].concat(arguments)

# Runs git in the temporary folder; a git that does not start, one whose output cannot be read and a non-zero status
# are PKG-FETCH at the git key, the last with the start of git's errors.
def git(place: Place, scratch: Scratch, arguments: List[String]) -> Result[Bytes]
  git_at(place, scratch, "git", arguments)
end

# The same, with a non-zero status reported at `key`: a command that fails because of one value of the entry (the
# subdir that the commit lacks) names that value.
def git_at(place: Place, scratch: Scratch, key: String, arguments: List[String]) -> Result[Bytes]
  case GitProcess.run(arguments, scratch.temp)
    GitProcess.Ran.Missing(message) ->
      error(fail(place, "PKG-FETCH", "git", "cannot run git: #{message}", "install git and put it on PATH"))
    GitProcess.Ran.Broken(message) ->
      error(fail(place, "PKG-FETCH", "git", "cannot read the output of git: #{message}", ""))
    GitProcess.Ran.Exited(status, output, errors) ->
      return error(fail(place, "PKG-FETCH", key, "git exited with status #{status}", brief(errors))) if status != 0

      ok(output)
  end
end

def git_text(place: Place, scratch: Scratch, arguments: List[String]) -> Result[String]
  output = try git(place, scratch, arguments)
  text = String.from_bytes(output)
  return error(fail(place, "PKG-FETCH", "git", "git gave text that is not UTF-8", "")) if !text.ok?

  ok(text.unwrap!)
end

# Whether the tag, a version of the repository, meets one ask.
def meets?(ask: Ask, tag: String, prefix: String) -> Bool
  return ask.tag == tag if ask.tag != ""

  requirement = VersionRequirement.parse(ask.text)
  requirement.ok? and VersionRequirement.tag_satisfies?(requirement.unwrap!, tag, prefix)
end

# "the project asks version ~> 1.0, package middle asks tag 1.2.0": every ask with its asker.
def who_asked(asks: List[Ask]) -> String
  words = asks.map do |ask: Ask|
    asker = "the project"
    if ask.by != ""
      asker = "package #{ask.by}"
    end

    wanted = "version #{ask.text}"
    if ask.tag != ""
      wanted = "tag #{ask.tag}"
    end

    "#{asker} asks #{wanted}"
  end

  words.join(", ")
end

def brief(errors: String) -> String
  text = errors.strip
  return text.slice(0, HELP_LIMIT) if text.length > HELP_LIMIT

  text
end
