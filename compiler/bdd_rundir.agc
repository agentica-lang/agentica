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

import {IO_TIMEOUT} from "bdd_files"

# How many names a run tries before it gives up: a name can be taken, and a hostile user could take names on purpose.
ATTEMPTS = 16
STALE_NEW_SECONDS = 3600
DIGITS = "0123456789abcdef"

## A claimed run directory: its final path, and the open lock file. The lock is released when the handle is closed.
export struct Run
  path: String
  lock: FileHandle
end

## The places that can hold the temporary directory, best first: TMPDIR when it is set, then /var/tmp, /usr/tmp and
## /tmp.
export def temporary_candidates() -> List[String]
  candidates: List[String] = []
  from_environment = System.env("TMPDIR")
  if from_environment.ok?
    candidates = candidates.push(from_environment.unwrap!)
  end
  return candidates.concat(["/var/tmp", "/usr/tmp", "/tmp"])
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
  current = try make_private(temporary)
  claimed = lock_and_name(temporary, current)
  if !claimed.ok?
    Path.remove(current, IO_TIMEOUT)
  end
  return claimed
end

## Removes the run directory and releases its lock. The removal is best effort: what stays is swept by a later run.
export def release(run: Run) -> Void
  Path.remove(run.path, IO_TIMEOUT)
  File.close(run.lock, IO_TIMEOUT)
end

## Removes the run directories of runs that have ended: the folders named `agentica-bdd-HEX` in `temporary`, and the
## old ones named `agentica-bdd-new-HEX`, made by the user of `own` (a folder of another user is never touched), that
## have a `lock` file nobody holds. `own` is not removed. A folder that cannot be inspected or removed stays.
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
    elsif hex_name?(name, "agentica-bdd-new-")
      age = STALE_NEW_SECONDS
    end
    if age >= 0
      held = abandoned(path, owner.unwrap!.user_id, age)
      if held.ok?
        Path.remove(path, IO_TIMEOUT)
        File.close(held.unwrap!, IO_TIMEOUT)
      end
    end
  end
end

## A random name: 16 bytes of /dev/urandom as 32 hex digits, so it cannot be guessed (Random.int has a 31-bit seed).
export def random_hex() -> Result[String]
  source = try File.open("/dev/urandom", "read", IO_TIMEOUT)
  bytes: List[Int] = []
  while bytes.size < 16
    got = File.read_bytes(source, 16 - bytes.size, IO_TIMEOUT)
    if !got.ok? or got.unwrap!.size == 0
      File.close(source, IO_TIMEOUT)
      return error("cannot read /dev/urandom")
    end
    bytes = bytes.concat(got.unwrap!)
  end
  try File.close(source, IO_TIMEOUT)
  digits = bytes.map do |byte: Int|
    "#{DIGITS.slice(byte.shift_right(4), 1)}#{DIGITS.slice(byte.bit_and(15), 1)}"
  end
  return ok(digits.join(""))
end

# The first free name among ATTEMPTS random ones. A name that is taken is skipped, and any other error ends the
# attempts the same way, with the last system error.
def make_private(temporary: String) -> Result[String]
  last = "no attempt was made"
  attempt = 0
  while attempt < ATTEMPTS
    name = try random_hex()
    path = try Path.join([temporary, "agentica-bdd-new-#{name}"])
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
  if shared
    return error("the temporary directory #{temporary} is shared and not sticky; set TMPDIR to a private folder")
  end
  name = try random_hex()
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
# not set. `own` is a folder we just made, so it tells our user and group.
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
# `owner` with a real `lock` file whose lock this call took, and not changed in the last `age` seconds. The handle
# keeps the folder from being claimed by another sweep until it is closed. A lock held by a live run is an error.
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
