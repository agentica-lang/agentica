## Fills the package cache from the lock (docs/future/45-packages.md, 45.8). One locked package goes into the folder of
## its commit: a depth-1 fetch of the tag (or of the commit) into a bare repository made for the purpose, with no hooks
## and no working tree, so nothing of the package runs. The files of the commit are read from its tree with `git
## ls-tree` and `git cat-file`, so `.gitattributes` does not change the bytes; only the `.agc` files and the manifest
## are copied (package_tree.agc), and the hash of what was copied must be the hash of the lock. A package that is a
## folder of the repository (`subdir`) is fetched the same way, but only the files of that folder are read and kept, in
## a cache folder of its own (package_cache.agc). The files are built in a folder of the cache root and renamed into
## place in one step, so the cache never holds half a package. A folder that is already in place is hashed, never
## overwritten. A failure is a packed failure that names the lock and the key of the entry (link_failure.agc,
## fail_key).
##
## `fill` fetches what the lock names. `resolve` (for `add` and `update`) fetches a pin that has no commit or hash yet,
## learns both from what it fetched, and puts the files in the cache by the same steps.

import Diag from "../diagnostics/diagnostic"
import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import Workspace from "../modules/workspace"
import GitSource from "../packages/git_source"
import Lock from "../packages/lock"
import PackageCache from "../packages/package_cache"
import PackageHash from "../packages/package_hash"
import Tree from "../packages/package_tree"
import Reader from "../packages/toml_read"
import GitProcess from "git_process"

# The deadline of one file-system call, in milliseconds.
FS_TIMEOUT_MS = 60_000
TEMP_TRIES = 5
# Where the fetched pin lands in the temporary repository. It is not under refs/tags/, so the name cannot clash with a
# tag of the repository.
PINNED = "refs/fetched/pin"
# The number of characters of git's error text that goes in the help.
HELP_LIMIT = 600

## What filling one package did: the files were fetched, or the folder was already there with the locked hash.
export enum Filled
  Fetched
  Present
end

## Where the package is in the lock: the file and the path of its `[[package]]` table, such as `package[2]`.
export struct Place
  file: String
  entry: String
end

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

## The folder of the package cache, or the failure for `file` (the lock, whose entries are about to be filled) when the
## environment leaves no place for it.
export def cache_root(env: Env.Env, file: String) -> Result[String]
  cache = PackageCache.root(env)
  if cache == ""
    message = "there is no package cache folder: HOME is not set"
    return error(Failure.fail_file(file, "PKG-FETCH", message, Failure.hint("set HOME or XDG_CACHE_HOME")))
  end

  return ok(cache)
end

## Like `cache_root`, for the packages of a lock: a lock of workspace members alone fetches nothing and needs no cache,
## so it gives "" for it and fails only when a package has to be fetched.
export def cache_for(env: Env.Env, file: String, packages: List[Lock.Locked]) -> Result[String]
  if packages.all? do |locked| locked.member end
    return ok("")
  end

  return cache_root(env, file)
end

## Puts the files of the locked package into the cache under `cache` (a folder; PackageCache.root).
export def fill(workspace: Workspace.Workspace, cache: String, place: Place, locked: Lock.Locked) -> Result[Filled]
  target = PackageCache.folder(cache, locked.source, locked.commit)
  seen = try inspect(workspace, place, target, locked)
  case seen
    Seen.Matches -> return ok(Filled.Present)
    Seen.Absent -> return fetch(workspace, cache, place, target, locked)
  end
end

## Fetches the pin of a package that is not locked yet, for `add` and `update`: the lock entry it gives has the commit
## that the pin points to and the hash of the files, and the files are in the cache as `fill` would put them. A tag may
## point anywhere now (that is what `update` is for); a `ref` must be the whole commit, since git cannot fetch an
## abbreviation. `place` names the dependency in the manifest that asks for it.
export def resolve(
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
  pin = Lock.Locked(name: name, source: source, commit: source.ref, hash: "", member: false)
  made = make_temp(cache)
  if !made.ok?
    return error(fail(place, "PKG-FETCH", "", "cannot make a folder in the package cache #{cache}", made.message))
  end

  temp = made.unwrap!
  scratch = Scratch(temp: temp, repo: Paths.join(temp, "repo.git"), files: Paths.join(temp, "files"))
  resolved = resolve_into(workspace, cache, place, scratch, pin)
  # As in fetch: a temporary folder that cannot be removed does not change the answer.
  remove_temp(temp)
  return resolved
end

## The failure for the key of an entry ("" for the entry as a whole). An empty help is no help.
export def fail(place: Place, code: String, key: String, message: String, help: String) -> String
  path = Reader.child(place.entry, key)
  if key == ""
    path = place.entry
  end

  if help == ""
    return Failure.fail_key(place.file, path, code, message, Diag.Help.NoHelp)
  end

  return Failure.fail_key(place.file, path, code, message, Failure.hint(help))
end

# Looks at the folder of the commit, if there is one: the locked files (nothing to do) or others (an error).
def inspect(workspace: Workspace.Workspace, place: Place, target: String, locked: Lock.Locked) -> Result[Seen]
  if !workspace.directory_exists.call(target) and !workspace.file_exists.call(target)
    return ok(Seen.Absent)
  end

  real = workspace.real_path.call(target)
  if !real.ok?
    return error(fail(place, "PKG-FETCH", "", "cannot read #{target}", real.message))
  end

  case PackageHash.hash_folder(workspace, real.unwrap!)
    PackageHash.Hashed.Hash(found) ->
      if found == locked.hash
        return ok(Seen.Matches)
      end

      message = "the files of #{locked.name} in the cache are not the ones the lock names"
      return error(fail(place, "PKG-HASH-MISMATCH", "hash", message, "remove #{target} and run install again"))
    PackageHash.Hashed.Link(path) ->
      return error(fail(place, "PKG-SYMLINK", "", "#{locked.name} has a symbolic link named #{path}", ""))
    PackageHash.Hashed.Unreadable(message) ->
      return error(fail(place, "PKG-FETCH", "", "cannot read #{target}", message))
  end
end

# Fetches into a temporary folder of the cache root, which is removed whatever happens.
def fetch(
  workspace: Workspace.Workspace,
  cache: String,
  place: Place,
  target: String,
  locked: Lock.Locked,
) -> Result[Filled]
  made = make_temp(cache)
  if !made.ok?
    return error(fail(place, "PKG-FETCH", "", "cannot make a folder in the package cache #{cache}", made.message))
  end

  temp = made.unwrap!
  scratch = Scratch(temp: temp, repo: Paths.join(temp, "repo.git"), files: Paths.join(temp, "files"))
  filled = fetch_into(workspace, place, scratch, target, locked)
  # A folder that cannot be removed stays hidden in the cache root, and the result of the install stands: the failure
  # to clean up is not worth failing a fetch that worked (or hiding the error of one that did not).
  remove_temp(temp)
  return filled
end

# git writes its objects read-only and Path.remove refuses a read-only entry on Windows, so `attrib` clears the
# attribute of the whole tree first. A failure of either step leaves the folder, as before. attrib runs in the working
# folder, not in `temp`: a running child holds its folder open on Windows, and then Path.remove could not remove it.
def remove_temp(temp: String) -> Void
  if System.os() == "windows"
    pattern = Paths.join(temp, "*").replace("/", "\\")
    spawned = Process.spawn_captured("attrib", ["-R", "/S", "/D", pattern], ".", FS_TIMEOUT_MS)
    if spawned.ok?
      child = spawned.unwrap!
      Process.wait(child, FS_TIMEOUT_MS)
      Process.close(child)
    end
  end

  Path.remove(temp, FS_TIMEOUT_MS)
end

# A new folder that only this process uses: mkdir_private fails when the name exists, so two installs never share one.
# It is hidden and directly under the root, where no host folder starts with a dot (GitSource.git_problem).
def make_temp(cache: String) -> Result[String]
  try Dir.mkdir(cache, FS_TIMEOUT_MS)
  failure = "no free name"
  for attempt in 0...TEMP_TRIES
    name = Paths.join(cache, ".tmp-#{System.pid()}-#{Random.int(0, 999_999_999)}")
    made = Dir.mkdir_private(name, FS_TIMEOUT_MS)
    if made.ok?
      return ok(name)
    end

    failure = made.message
  end

  return error(failure)
end

def fetch_into(
  workspace: Workspace.Workspace,
  place: Place,
  scratch: Scratch,
  target: String,
  locked: Lock.Locked,
) -> Result[Filled]
  try init_repository(place, scratch, locked)
  try fetch_pin(place, scratch, locked)
  try check_commit(place, scratch, locked)
  try copy_tree(place, scratch, locked.commit, locked.source.subdir)
  try check_hash(workspace, place, scratch.files, locked)
  return move_into_place(workspace, place, scratch.files, target, locked)
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
    Tree.Plan.Refused(fault) -> return error(fail(place, fault.code, fault.key, fault.message, fault.help))
    Tree.Plan.Files(blobs) -> return copy_blobs(place, scratch, blobs)
  end
end

# The subdir must be a folder of the commit. Only this question is answered at the subdir key: the commit was fetched
# and peeled already, so a path that git cannot find, or that is a file, a link or a submodule (git cannot read the
# commit it names), is the entry's fault, while a later failure of git (ls-tree, a damaged repository) is git's.
def check_subdir(place: Place, scratch: Scratch, tree: String) -> Result[Void]
  kind = try git_at(place, scratch, "subdir", inside(scratch, ["cat-file", "-t", tree]))
  if String.from_bytes(kind).unwrap_or("").trim != "tree"
    return error(fail(place, "PKG-FETCH", "subdir", "#{tree} is not a folder", ""))
  end

  return ok()
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
  locked = Lock.Locked(name: pin.name, source: pin.source, commit: commit, hash: hash, member: false)
  target = PackageCache.folder(cache, locked.source, commit)
  try move_into_place(workspace, place, scratch.files, target, locked)
  return ok(locked)
end

# An empty template, so a hook from the user's template folder cannot run.
def init_repository(place: Place, scratch: Scratch, locked: Lock.Locked) -> Result[Void]
  arguments = ["init", "--bare", "--quiet", "--template="]
  if locked.commit.length == 64
    arguments = arguments.push("--object-format=sha256")
  end

  try git(place, scratch, arguments.push(scratch.repo))
  return ok()
end

# The url is passed as written: git's own url.<base>.insteadOf settings apply to it, and the lock keeps what the
# manifest says (45.6).
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
  return ok()
end

# The fetched pin must be the locked commit; a tag that now points elsewhere is a moved tag, never a new lock.
def check_commit(place: Place, scratch: Scratch, locked: Lock.Locked) -> Result[Void]
  commit = try peel(place, scratch)
  if commit == locked.commit
    return ok()
  end

  if locked.source.tag != ""
    message = "the tag #{locked.source.tag} of #{locked.name} is now #{commit}, and the lock has #{locked.commit}"
    return error(fail(place, "PKG-TAG-MOVED", "tag", message, "the lock is not changed; update it on purpose"))
  end

  return error(fail(place, "PKG-FETCH", "commit", "git fetched #{commit}, not #{locked.commit}", ""))
end

# The commit that the fetched pin points to (a tag is peeled).
def peel(place: Place, scratch: Scratch) -> Result[String]
  arguments = ["rev-parse", "--verify", "--quiet", "#{PINNED}^{commit}"]
  peeled = try git_text(place, scratch, inside(scratch, arguments))
  return ok(peeled.trim)
end

def copy_blobs(place: Place, scratch: Scratch, blobs: List[Tree.Blob]) -> Result[Void]
  made = Dir.mkdir(scratch.files, FS_TIMEOUT_MS)
  if !made.ok?
    return error(fail(place, "PKG-FETCH", "", "cannot make #{scratch.files}", made.message))
  end

  for blob in blobs
    data = try git(place, scratch, inside(scratch, ["cat-file", "blob", blob.oid]))
    try write_file(place, Paths.join(scratch.files, blob.path), data)
  end

  return ok()
end

# A file is at most Tree.MAX_FILE_BYTES (1 MiB, the most File.write_bytes takes in one call), so it goes in one write.
def write_file(place: Place, path: String, data: Bytes) -> Result[Void]
  folder = Paths.directory_of(path)
  made = Dir.mkdir(folder, FS_TIMEOUT_MS)
  if !made.ok?
    return error(fail(place, "PKG-FETCH", "", "cannot make #{folder}", made.message))
  end

  opened = File.open(path, "write", FS_TIMEOUT_MS)
  if !opened.ok?
    return error(fail(place, "PKG-FETCH", "", "cannot write #{path}", opened.message))
  end

  handle = opened.unwrap!
  wrote = File.write_bytes(handle, data, FS_TIMEOUT_MS)
  if !wrote.ok?
    File.close(handle, FS_TIMEOUT_MS)
    return error(fail(place, "PKG-FETCH", "", "cannot write #{path}", wrote.message))
  end

  closed = File.close(handle, FS_TIMEOUT_MS)
  if !closed.ok?
    return error(fail(place, "PKG-FETCH", "", "cannot write #{path}", closed.message))
  end

  return ok()
end

def check_hash(workspace: Workspace.Workspace, place: Place, files: String, locked: Lock.Locked) -> Result[Void]
  found = try hash_of(workspace, place, locked, files)
  if found == locked.hash
    return ok()
  end

  message = "the files fetched for #{locked.name} are not the ones the lock names (#{found})"
  return error(fail(place, "PKG-HASH-MISMATCH", "hash", message, "the lock is not changed; update it on purpose"))
end

# The hash of the fetched files (the pin's, or the locked entry's, name is only for the messages).
def hash_of(workspace: Workspace.Workspace, place: Place, locked: Lock.Locked, files: String) -> Result[String]
  case PackageHash.hash_folder(workspace, files)
    PackageHash.Hashed.Hash(found) -> return ok(found)
    PackageHash.Hashed.Link(path) ->
      return error(fail(place, "PKG-SYMLINK", "", "#{locked.name} has a symbolic link named #{path}", ""))
    PackageHash.Hashed.Unreadable(message) ->
      return error(fail(place, "PKG-FETCH", "", "cannot read the fetched files of #{locked.name}", message))
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
  if !made.ok?
    return error(fail(place, "PKG-FETCH", "", "cannot make the folder of #{target}", made.message))
  end

  moved = Path.rename(files, target, FS_TIMEOUT_MS)
  if moved.ok?
    return ok(Filled.Fetched)
  end

  seen = try inspect(workspace, place, target, locked)
  case seen
    Seen.Matches -> return ok(Filled.Present)
    Seen.Absent -> return error(fail(place, "PKG-FETCH", "", "cannot move the files to #{target}", moved.message))
  end
end

# The arguments of a git command that works on the temporary repository.
def inside(scratch: Scratch, arguments: List[String]) -> List[String]
  return ["--git-dir=#{scratch.repo}"].concat(arguments)
end

# Runs git in the temporary folder; a git that does not start, one whose output cannot be read and a non-zero status
# are PKG-FETCH at the git key, the last with the start of git's errors.
def git(place: Place, scratch: Scratch, arguments: List[String]) -> Result[Bytes]
  return git_at(place, scratch, "git", arguments)
end

# The same, with a non-zero status reported at `key`: a command that fails because of one value of the entry (the
# subdir that the commit lacks) names that value.
def git_at(place: Place, scratch: Scratch, key: String, arguments: List[String]) -> Result[Bytes]
  case GitProcess.run(arguments, scratch.temp)
    GitProcess.Ran.Missing(message) ->
      return error(fail(place, "PKG-FETCH", "git", "cannot run git: #{message}", "install git and put it on PATH"))
    GitProcess.Ran.Broken(message) ->
      return error(fail(place, "PKG-FETCH", "git", "cannot read the output of git: #{message}", ""))
    GitProcess.Ran.Exited(status, output, errors) ->
      if status != 0
        return error(fail(place, "PKG-FETCH", key, "git exited with status #{status}", brief(errors)))
      end

      return ok(output)
  end
end

def git_text(place: Place, scratch: Scratch, arguments: List[String]) -> Result[String]
  output = try git(place, scratch, arguments)
  text = String.from_bytes(output)
  if !text.ok?
    return error(fail(place, "PKG-FETCH", "git", "git gave text that is not UTF-8", ""))
  end

  return ok(text.unwrap!)
end

def brief(errors: String) -> String
  text = errors.trim
  if text.length > HELP_LIMIT
    return text.slice(0, HELP_LIMIT)
  end

  return text
end
