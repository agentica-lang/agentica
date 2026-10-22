## The directory of a BDD run: a private folder in the temporary directory that holds the compiled
## runner, the test programs, the configuration and the report, and a locked file that says the run is alive.
##
## A run takes its folder in this order, so no other run can ever find it half made:
##
## 1. `Dir.mkdir_private` makes `agentica-bdd-new-HEX` (mode 0700; it fails when the name exists, so the run never
##    ends up in a folder it did not make).
## 2. A file `lock` is created in it and locked (`File.try_lock`). The lock belongs to the open file, so it ends with
##    the run, also when the run is killed.
## 3. `Path.rename` gives it its final name `agentica-bdd-HEX`, and never replaces a name that is taken.
##
## The sweep looks at final names, so it never meets a folder without a lock. A final name whose lock can be taken
## belongs to a run that has ended, and the sweep removes it. A run killed between steps 1 and 3 leaves an
## `agentica-bdd-new-HEX`; the sweep removes it too, on the same checks, but only when it has not changed for an hour,
## because a run that is alive is in step 1 or 2 for a moment and has no lock held yet.
##
## Windows cannot rename a folder that holds a file somebody has open, so there the run makes the final name in step 1
## and has no step 3. For the same reason the sweep leaves a final name alone until it is a minute old on Windows
## (WINDOWS_MIN_AGE_SECONDS), so a run that is still starting is not taken by a run that overlaps it. What is left is
## a residual case: a sweep that meets the folder between the creation of `lock` and the lock itself would take the
## lock first and the run would fail to lock (`claim` is an error then). It needs a clock that is a minute off or an
## mtime that is not updated, so it is not expected in practice.
## `discard` on Windows closes the lock and then removes the folder, which is not atomic, but both sides are best
## effort, so a lost race only leaves the folder for a later sweep.
##
## Windows has no sticky bit, so a run there refuses a temporary folder that others can change: `File.stat` gives a
## Windows folder the group and other write bits when its owner is not the user, SYSTEM or Administrators, or its
## access list lets anyone else add, replace or delete its entries (see `shared_and_not_sticky?`). In the folder that
## is left, as the default per-user one is, no other user can replace the run folder before `lock` pins it, and there
## are no folders of other users for the sweep to take.

import RandomName from "../io/random_name"
import {IO_TIMEOUT} from "bdd_files"

# How many names a run tries before it gives up: a name can be taken, and a hostile user could take names on purpose.
ATTEMPTS = 16
STALE_NEW_SECONDS = 3600
WINDOWS_MIN_AGE_SECONDS = 60
DIGITS = "0123456789abcdef"

## A claimed run directory: its final path, and the open lock file. The lock is released when the handle is closed.
export struct Run
  path: String
  lock: FileHandle
end

## The places that can hold the temporary directory, best first. On Windows: the variables TMPDIR, TMP and TEMP in
## that order (TMP and TEMP are the first two that `GetTempPath` reads) and no fixed folder. Elsewhere: TMPDIR when it
## is set, then /var/tmp, /usr/tmp and /tmp.
export def temporary_candidates() -> List[String]
  candidates: List[String] = []
  names = ["TMPDIR"]
  fixed: List[String] = ["/var/tmp", "/usr/tmp", "/tmp"]
  if windows?()
    names = ["TMPDIR", "TMP", "TEMP"]
    fixed = []
  end
  for name in names
    from_environment = System.env(name)
    if from_environment.ok?
      candidates = candidates.push(from_environment.unwrap!)
    end
  end
  return candidates.concat(fixed)
end

## The temporary directory: the first of `temporary_candidates()` that is a directory.
export def temporary_directory() -> Result[String]
  candidates = temporary_candidates()
  for path in candidates
    info = File.stat(path, IO_TIMEOUT)
    if info.ok? and info.unwrap!.kind == "directory"
      return ok(path)
    end
  end
  return error("no temporary directory: none of #{candidates.join(", ")} is a directory")
end

## Makes the run directory in `temporary`, locked and under its final name. Nothing is left behind on a failure.
export def claim(temporary: String) -> Result[Run]
  prefix = "agentica-bdd-new-"
  if windows?()
    prefix = "agentica-bdd-"
  end
  current = try make_private(temporary, prefix)
  claimed = lock_and_name(temporary, current)
  if !claimed.ok?
    Path.remove(current, IO_TIMEOUT)
  end
  return claimed
end

## Removes the run directory and releases its lock. The removal is best effort: what stays is swept by a later run.
export def release(run: Run) -> Void
  discard(run.path, run.lock)
end

## Removes the run directories of runs that have ended: the folders named `agentica-bdd-HEX` in `temporary`, and the
## old ones named `agentica-bdd-new-HEX`, made by the user of `own` (a folder of another user is never touched), that
## have a `lock` file nobody holds. `own` is not removed. A folder that cannot be inspected or removed stays. On
## Windows the user id is 0 for every folder, so it does not tell the users apart; there `claim` takes only a
## temporary folder that no other user can write, so no other user's folder is in it.
export def sweep(temporary: String, own: Run) -> Void
  owner = File.lstat(own.path, IO_TIMEOUT)
  names = Dir.list(temporary, IO_TIMEOUT)
  if !owner.ok? or !names.ok?
    return
  end
  for name in names.unwrap!
    joined = Path.join([temporary, name])
    if !joined.ok?
      next
    end
    path = joined.unwrap!
    # The minimum age in seconds of the folder to remove, or -1 for a name that is not a run directory.
    age = -1
    if hex_name?(name, "agentica-bdd-") and path != own.path
      age = 0
      if windows?()
        age = WINDOWS_MIN_AGE_SECONDS
      end
    elsif hex_name?(name, "agentica-bdd-new-")
      age = STALE_NEW_SECONDS
    end
    if age >= 0
      held = abandoned(path, owner.unwrap!.user_id, age)
      if held.ok?
        discard(path, held.unwrap!)
      end
    end
  end
end

# Whether the run is on Windows, where the temporary folder, the random names and the ownership checks differ.
def windows?() -> Bool
  return System.os() == "windows"
end

# Removes the run folder and releases its lock. Elsewhere the lock is held until the folder is gone, so no other sweep
# takes the same folder; Windows cannot remove a folder with an open file in it, so the lock is closed first there.
def discard(path: String, lock: FileHandle) -> Void
  if windows?()
    File.close(lock, IO_TIMEOUT)
    Path.remove(path, IO_TIMEOUT)
  else
    Path.remove(path, IO_TIMEOUT)
    File.close(lock, IO_TIMEOUT)
  end
end

# The first free name among ATTEMPTS random ones, made as `prefix` and the name. A name that is taken is skipped, and
# any other error ends the attempts the same way, with the last system error.
def make_private(temporary: String, prefix: String) -> Result[String]
  last = "no attempt was made"
  attempt = 0
  while attempt < ATTEMPTS
    name = try RandomName.hex()
    path = try Path.join([temporary, "#{prefix}#{name}"])
    made = Dir.mkdir_private(path, IO_TIMEOUT)
    if made.ok?
      return ok(path)
    end
    last = made.message
    attempt += 1
  end
  return error("cannot make a private directory in #{temporary}: #{last}")
end

def lock_and_name(temporary: String, current: String) -> Result[Run]
  shared = try shared_and_not_sticky?(temporary, current)
  if shared and windows?()
    return error("others can change the entries of the temporary directory #{temporary}; set TMP to a private folder")
  elsif shared
    return error("the temporary directory #{temporary} is shared and not sticky; set TMPDIR to a private folder")
  end
  if windows?()
    lock = try take_lock(current)
    return ok(Run(path: current, lock: lock))
  end
  name = try RandomName.hex()
  final = try Path.join([temporary, "agentica-bdd-#{name}"])
  lock = try take_lock(current)
  renamed = Path.rename(current, final, IO_TIMEOUT)
  if !renamed.ok?
    File.close(lock, IO_TIMEOUT)
    return error("cannot name the run directory #{final}: #{renamed.message}")
  end
  return ok(Run(path: final, lock: lock))
end

# Creates the lock file and locks it. It is a new file, so a name in the way is an error and never a link followed.
def take_lock(directory: String) -> Result[FileHandle]
  path = try Path.join([directory, "lock"])
  lock = try File.open(path, "create_private", IO_TIMEOUT)
  taken = File.try_lock(lock, IO_TIMEOUT)
  if taken.ok? and taken.unwrap!
    return ok(lock)
  end
  File.close(lock, IO_TIMEOUT)
  return error("cannot lock #{directory}")
end

# A temporary directory where other users can write and delete our entries is not safe for a run that trusts its
# files: it is the case when others can write (mode o+w) or the group can write (g+w) and the directory is not ours
# alone in user and group without the setgid bit, and the sticky bit (which stops others from deleting our entries) is
# not set. `own` is a folder we just made, so it tells our user and group. On Windows the user and group ids are 0 and
# there is no sticky or setgid bit, and a folder has both write bits when anyone but the user, SYSTEM and
# Administrators may change its entries (from its owner and access list), so the same test refuses it.
def shared_and_not_sticky?(temporary: String, own: String) -> Result[Bool]
  folder = try File.stat(temporary, IO_TIMEOUT)
  mine = try File.lstat(own, IO_TIMEOUT)
  mode = folder.mode
  if mode.bit_and(512) != 0
    return ok(false)
  end
  others_write = mode.bit_and(2) != 0
  group_write = mode.bit_and(16) != 0
  setgid = mode.bit_and(1024) != 0
  ours_alone = folder.user_id == mine.user_id and folder.group_id == mine.group_id and !setgid
  return ok(others_write or (group_write and !ours_alone))
end

# The prefix and then hexadecimal digits only. `agentica-bdd-` is the final name of a run, `agentica-bdd-new-` a run
# being made (the "n" of "new" is not a digit, so the first never matches the second).
def hex_name?(name: String, prefix: String) -> Bool
  if !name.starts_with?(prefix) or name.length == prefix.length
    return false
  end
  for digit in name.slice(prefix.length, name.length - prefix.length).split("")
    if !DIGITS.contains?(digit)
      return false
    end
  end
  return true
end

# The lock of a folder that may belong to a run that ended: ok(handle) when the folder is a real folder (not a link) of
# `owner` (on Windows every folder has the user id 0; see `sweep`) with a real `lock` file whose lock this call took,
# and not changed in the last `age` seconds. The handle keeps the folder from being claimed by another sweep until it
# is closed. A lock held by a live run is an error.
def abandoned(path: String, owner: Int, age: Int) -> Result[FileHandle]
  folder = try File.lstat(path, IO_TIMEOUT)
  lock_path = try Path.join([path, "lock"])
  lock_info = try File.lstat(lock_path, IO_TIMEOUT)
  if folder.kind != "directory" or folder.user_id != owner or lock_info.kind != "file"
    return error("not a run directory")
  end
  if age > 0 and Time.now_ms() / 1000 - folder.modified_seconds < age
    return error("too new to be abandoned")
  end
  lock = try File.open(lock_path, "read", IO_TIMEOUT)
  taken = File.try_lock(lock, IO_TIMEOUT)
  if taken.ok? and taken.unwrap!
    return ok(lock)
  end
  File.close(lock, IO_TIMEOUT)
  return error("the run is alive")
end
