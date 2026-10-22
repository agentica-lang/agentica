## Fills the package cache from the lock (docs/future/45-packages.md, 45.8). One locked package goes into the folder of
## its commit: a depth-1 fetch of the tag (or of the commit) into a bare repository made for the purpose, with no hooks
## and no working tree, so nothing of the package runs. The files of the commit are read from its tree with `git
## ls-tree` and `git cat-file`, so `.gitattributes` does not change the bytes; only the `.agc` files and the manifest
## are copied (package_tree.agc), and the hash of what was copied must be the hash of the lock. The files are built in
## a folder of the cache root and renamed into place in one step, so the cache never holds half a package. A folder
## that is already in place is hashed, never overwritten. A failure is a packed failure that names the lock and the
## key of the entry (link_failure.agc, fail_key).

import Diag from "../diagnostics/diagnostic"
import Paths from "../modules/import_path"
import Failure from "../modules/link_failure"
import Workspace from "../modules/workspace"
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

## Puts the files of the locked package into the cache under `cache` (a folder; PackageCache.root).
export def fill(workspace: Workspace.Workspace, cache: String, place: Place, locked: Lock.Locked) -> Result[Filled]
  target = PackageCache.folder(cache, locked.source.git, locked.commit)
  seen = try inspect(workspace, place, target, locked)
  case seen
    Seen.Matches -> return ok(Filled.Present)
    Seen.Absent -> return fetch(workspace, cache, place, target, locked)
  end
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
  Path.remove(temp, FS_TIMEOUT_MS)
  return filled
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
  listing = try git_text(place, scratch, inside(scratch, ["ls-tree", "-r", "-z", "-l", locked.commit]))
  case Tree.plan(listing)
    Tree.Plan.Refused(fault) -> return error(fail(place, fault.code, fault.key, fault.message, fault.help))
    Tree.Plan.Files(blobs) -> try copy_blobs(place, scratch, blobs)
  end
  try check_hash(workspace, place, scratch.files, locked)
  return move_into_place(workspace, place, scratch.files, target, locked)
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
    "fetch", "--quiet", "--depth=1", "--no-tags", "--no-recurse-submodules", "--", locked.source.git,
    "+#{wanted}:#{PINNED}",
  ]
  try git(place, scratch, inside(scratch, arguments))
  return ok()
end

# The fetched pin must be the locked commit; a tag that now points elsewhere is a moved tag, never a new lock.
def check_commit(place: Place, scratch: Scratch, locked: Lock.Locked) -> Result[Void]
  peeled = try git_text(place, scratch, inside(scratch, ["rev-parse", "--verify", "--quiet", "#{PINNED}^{commit}"]))
  commit = peeled.trim
  if commit == locked.commit
    return ok()
  end
  if locked.source.tag != ""
    message = "the tag #{locked.source.tag} of #{locked.name} is now #{commit}, and the lock has #{locked.commit}"
    return error(fail(place, "PKG-TAG-MOVED", "tag", message, "the lock is not changed; update it on purpose"))
  end
  return error(fail(place, "PKG-FETCH", "commit", "git fetched #{commit}, not #{locked.commit}", ""))
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
def write_file(place: Place, path: String, data: List[Int]) -> Result[Void]
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
  case PackageHash.hash_folder(workspace, files)
    PackageHash.Hashed.Hash(found) ->
      if found == locked.hash
        return ok()
      end
      message = "the files fetched for #{locked.name} are not the ones the lock names (#{found})"
      return error(fail(place, "PKG-HASH-MISMATCH", "hash", message, "the lock is not changed; update it on purpose"))
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
def git(place: Place, scratch: Scratch, arguments: List[String]) -> Result[List[Int]]
  case GitProcess.run(arguments, scratch.temp)
    GitProcess.Ran.Missing(message) ->
      return error(fail(place, "PKG-FETCH", "git", "cannot run git: #{message}", "install git and put it on PATH"))
    GitProcess.Ran.Broken(message) ->
      return error(fail(place, "PKG-FETCH", "git", "cannot read the output of git: #{message}", ""))
    GitProcess.Ran.Exited(status, output, errors) ->
      if status != 0
        return error(fail(place, "PKG-FETCH", "git", "git exited with status #{status}", brief(errors)))
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
